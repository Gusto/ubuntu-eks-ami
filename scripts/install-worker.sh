#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

IFS=$'\n\t'

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}

################################################################################
### Validate Required Arguments ################################################
################################################################################
validate_env_set() {
  (
    set +o nounset

    if [ -z "${!1}" ]; then
      echo "Packer variable '$1' was not set. Aborting"
      exit 1
    fi
  )
}

validate_env_set BINARY_BUCKET_NAME
validate_env_set BINARY_BUCKET_REGION
validate_env_set DOCKER_VERSION
validate_env_set CONTAINERDIO_VERSION
validate_env_set CNI_PLUGIN_VERSION
validate_env_set KUBERNETES_VERSION
validate_env_set KUBERNETES_BUILD_DATE
validate_env_set PULL_CNI_FROM_GITHUB

################################################################################
### Machine Architecture #######################################################
################################################################################

MACHINE=$(uname -m)
if [ "$MACHINE" == "x86_64" ]; then
  ARCH="amd64"
elif [ "$MACHINE" == "aarch64" ]; then
  ARCH="arm64"
else
  echo "Unknown machine architecture '$MACHINE'" >&2
  exit 1
fi

################################################################################
### Packages ###################################################################
################################################################################

# Update the OS to begin with to catch up to the latest packages.
sudo add-apt-repository universe
sudo apt-get update -y

# It should be noted that this installs awscli 1.14, which does not contain EKS.
# We install the latest version of the awscli further down, after pip3 has been installed
sudo apt-get install -y \
  conntrack \
  chrony \
  socat \
  unzip \
  jq \
  nfs-kernel-server \
  wget \
  ipvsadm
# @sinneduy: we will skip this for now, it looks like it overrides ssh configs.
#ec2-instance-connect

# @sinneduy: We are not going to bother to make sure ec2-net-utils is not installed
# https://github.com/awslabs/amazon-eks-ami/compare/b85ef2fce5f46eddafa2e8881d757b31a9feed81...4e0e9164885e07851ed4a737461349ae6012765e#diff-fa7aab304e6b43e978fe591811173fa9R67

################################################################################
### Time #######################################################################
################################################################################

# Make sure Amazon Time Sync Service starts on boot.
update-rc.d chrony defaults 80 20

# Make sure that chronyd syncs RTC clock to the kernel.
# This can be commented out because this is set in the chrony config by default
#cat <<EOF | sudo tee -a /etc/chrony.conf
## This directive enables kernel synchronisation (every 11 minutes) of the
## real-time clock. Note that it can’t be used along with the 'rtcfile' directive.
#rtcsync
#EOF

# However, chrony does not use Amazon Time Sync Service by default in Ubuntu
# So, we will have to configure it to prefer it according to this:
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html#configure-amazon-time-service-ubuntu

sudo sed -i '1s/^/server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4\n/' /etc/chrony/chrony.conf

# If current clocksource is xen, switch to tsc
# @sinneduy: This probably won't work in ubuntu, should probably try to validate it later
if grep --quiet xen /sys/devices/system/clocksource/clocksource0/current_clocksource &&
  grep --quiet tsc /sys/devices/system/clocksource/clocksource0/available_clocksource; then
  echo "tsc" | sudo tee /sys/devices/system/clocksource/clocksource0/current_clocksource
else
  echo "tsc as a clock source is not applicable, skipping."
fi

sudo apt-get install -y \
  build-essential \
  checkinstall
sudo apt-get install -y \
  libreadline-gplv2-dev \
  libncursesw5-dev \
  libssl-dev \
  libsqlite3-dev \
  tk-dev \
  libgdbm-dev \
  libc6-dev \
  libbz2-dev

sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  software-properties-common

sudo apt-get install -y python3-pip

# Ubuntu's package repositories don't use a version of awscli that has eks
sudo pip3 install awscli

# Install aws-cfn-bootstrap directly, instead of via apt
sudo apt-get install -y python2.7
sudo apt-get install -y python-pip
sudo pip install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz

sudo ln -s /root/aws-cfn-bootstrap-latest/init/ubuntu/cfn-hup /etc/init.d/cfn-hup

################################################################################
### iptables ###################################################################
################################################################################

# Enable forwarding via iptables
sudo bash -c "iptables-save > /etc/network/iptables"

sudo mv $TEMPLATE_DIR/iptables-restore.service /etc/systemd/system/iptables-restore.service

sudo systemctl daemon-reload
sudo systemctl enable iptables-restore

################################################################################
### Docker #####################################################################
################################################################################

INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
if [[ "$INSTALL_DOCKER" == "true" ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo apt-key fingerprint 0EBFCD88
  sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) \
     stable"
  cat /etc/apt/sources.list
  sudo apt-get update -y
  sudo groupadd -fog 1950 docker
  sudo useradd --gid $(getent group docker | cut -d: -f3) docker
  sudo apt-get install -y docker-ce=${DOCKER_VERSION}
  sudo usermod -aG docker $USER

  # install condtainerd.io, which includes containerd and runc
  sudo apt-get install -y containerd.io=${CONTAINERDIO_VERSION} --allow-downgrades

  sudo mkdir -p /etc/docker
  sudo mv $TEMPLATE_DIR/docker-daemon.json /etc/docker/daemon.json
  sudo chown root:root /etc/docker/daemon.json

  # Enable docker daemon to start on boot.
  sudo systemctl daemon-reload
  sudo systemctl enable docker
fi

################################################################################
### Logrotate ##################################################################
################################################################################

# kubelet uses journald which has built-in rotation and capped size.
# See man 5 journald.conf
sudo mv $TEMPLATE_DIR/logrotate-kube-proxy /etc/logrotate.d/kube-proxy
sudo mv $TEMPLATE_DIR/logrotate.conf /etc/logrotate.conf
sudo chown root:root /etc/logrotate.d/kube-proxy
sudo chown root:root /etc/logrotate.conf
sudo mkdir -p /var/log/journal

################################################################################
### Kubernetes #################################################################
################################################################################

sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/kubernetes
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /opt/cni/bin

# Install kubelet
# @sinneduy It should be noted that this diverges significantly from how amazon-eks-ami installs the kubelet and kubectl binaries
# https://github.com/awslabs/amazon-eks-ami/blob/master/install-worker.sh#L143-L170
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo bash -c "cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF"

sudo apt-get update -y

sudo apt-get install -y kubelet=$KUBERNETES_VERSION-00
sudo apt-mark hold kubelet

# Since CNI 0.7.0, all releases are done in the plugins repo.
CNI_PLUGIN_FILENAME="cni-plugins-linux-${ARCH}-${CNI_PLUGIN_VERSION}"

if [ "$PULL_CNI_FROM_GITHUB" = "true" ]; then
  echo "Downloading CNI plugins from Github"
  wget "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/${CNI_PLUGIN_FILENAME}.tgz"
  wget "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/${CNI_PLUGIN_FILENAME}.tgz.sha512"
  sudo sha512sum -c "${CNI_PLUGIN_FILENAME}.tgz.sha512"
  rm "${CNI_PLUGIN_FILENAME}.tgz.sha512"
else
  # @sinneduy: since we don't download kubelet from an s3 bucket, we only need it if we are in this else statement
  S3_DOMAIN="amazonaws.com"
  if [ "$BINARY_BUCKET_REGION" = "cn-north-1" ] || [ "$BINARY_BUCKET_REGION" = "cn-northwest-1" ]; then
    S3_DOMAIN="amazonaws.com.cn"
  elif [ "$BINARY_BUCKET_REGION" = "us-iso-east-1" ]; then
    S3_DOMAIN="c2s.ic.gov"
  elif [ "$BINARY_BUCKET_REGION" = "us-isob-east-1" ]; then
    S3_DOMAIN="sc2s.sgov.gov"
  fi
  S3_URL_BASE="https://$BINARY_BUCKET_NAME.s3.$BINARY_BUCKET_REGION.$S3_DOMAIN/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"
  S3_PATH="s3://$BINARY_BUCKET_NAME/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"

  if [[ -n "$AWS_ACCESS_KEY_ID" ]]; then
    echo "AWS cli present - using it to copy binaries from s3."
    aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/${CNI_PLUGIN_FILENAME}.tgz .
    aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/${CNI_PLUGIN_FILENAME}.tgz.sha256 .
  else
    echo "AWS cli missing - using wget to fetch cni binaries from s3. Note: This won't work for private bucket."
    sudo wget "$S3_URL_BASE/${CNI_PLUGIN_FILENAME}.tgz"
    sudo wget "$S3_URL_BASE/${CNI_PLUGIN_FILENAME}.tgz.sha256"
  fi
  sudo sha256sum -c "${CNI_PLUGIN_FILENAME}.tgz.sha256"
  sudo rm ./*.sha256
fi

sudo tar -xvf "${CNI_PLUGIN_FILENAME}.tgz" -C /opt/cni/bin
rm "${CNI_PLUGIN_FILENAME}.tgz"


sudo mkdir -p /etc/kubernetes/kubelet
sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo mv $TEMPLATE_DIR/kubelet-kubeconfig /var/lib/kubelet/kubeconfig
sudo chown root:root /var/lib/kubelet/kubeconfig
sudo mv $TEMPLATE_DIR/kubelet.service /etc/systemd/system/kubelet.service
sudo chown root:root /etc/systemd/system/kubelet.service
# Inject CSIServiceAccountToken feature gate to kubelet config if kubernetes version starts with 1.20.
# This is only injected for 1.20 since CSIServiceAccountToken will be moved to beta starting 1.21.
if [[ $KUBERNETES_VERSION == "1.20"* ]]; then
    KUBELET_CONFIG_WITH_CSI_SERVICE_ACCOUNT_TOKEN_ENABLED=$(cat $TEMPLATE_DIR/kubelet-config.json | jq '.featureGates += {CSIServiceAccountToken: true}')
    echo $KUBELET_CONFIG_WITH_CSI_SERVICE_ACCOUNT_TOKEN_ENABLED > $TEMPLATE_DIR/kubelet-config.json
fi
sudo mv $TEMPLATE_DIR/kubelet-config.json /etc/kubernetes/kubelet/kubelet-config.json
sudo chown root:root /etc/kubernetes/kubelet/kubelet-config.json

sudo systemctl daemon-reload
# Disable the kubelet until the proper dropins have been configured
sudo systemctl disable kubelet

################################################################################
### EKS ########################################################################
################################################################################

sudo mkdir -p /etc/eks
sudo mv $TEMPLATE_DIR/eni-max-pods.txt /etc/eks/eni-max-pods.txt
sudo mv $TEMPLATE_DIR/bootstrap.sh /etc/eks/bootstrap.sh
sudo chmod +x /etc/eks/bootstrap.sh

SONOBUOY_E2E_REGISTRY="${SONOBUOY_E2E_REGISTRY:-}"
if [[ -n "$SONOBUOY_E2E_REGISTRY" ]]; then
    sudo mv $TEMPLATE_DIR/sonobuoy-e2e-registry-config /etc/eks/sonobuoy-e2e-registry-config
    sudo sed -i s,SONOBUOY_E2E_REGISTRY,$SONOBUOY_E2E_REGISTRY,g /etc/eks/sonobuoy-e2e-registry-config
fi

################################################################################
### SSM Agent ##################################################################
################################################################################

# The EC2 instance should already have the SSM agent installed
# https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-manual-agent-install.html
# You can check the agent status by running sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service

################################################################################
### AMI Metadata ###############################################################
################################################################################

BASE_AMI_ID=$(curl -s http://169.254.169.254/latest/meta-data/ami-id)
cat <<EOF >/tmp/release
BASE_AMI_ID="$BASE_AMI_ID"
BUILD_TIME="$(date)"
BUILD_KERNEL="$(uname -r)"
AMI_NAME="$AMI_NAME"
ARCH="$(uname -m)"
EOF
sudo mv /tmp/release /etc/eks/release
sudo chown -R root:root /etc/eks/

################################################################################
### Stuff required by "protectKernelDefaults=true" #############################
################################################################################

cat <<EOF | sudo tee -a /etc/sysctl.d/99-amazon.conf
vm.overcommit_memory=1
kernel.panic=10
kernel.panic_on_oops=1
EOF

################################################################################
### Setting up sysctl properties ###############################################
################################################################################

echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_user_instances=8192 | sudo tee -a /etc/sysctl.conf
echo vm.max_map_count=524288 | sudo tee -a /etc/sysctl.conf

################################################################################
### https://twitter.com/0xdabbad00/status/1281608156909469696 ##################
### https://aws.amazon.com/security/security-bulletins/AWS-2020-002/ ###########
### https://github.com/kubernetes/kubernetes/issues/92315 ######################
### This can be removed after we have upgraded kubelet AND kube-proxy ##########
################################################################################
sudo iptables -I INPUT --dst 127.0.0.0/8 ! --src 127.0.0.0/8 \
  -m conntrack ! --ctstate RELATED,ESTABLISHED,DNAT -j DROP

################################################################################
### Cleanup ####################################################################
################################################################################

CLEANUP_IMAGE="${CLEANUP_IMAGE:-true}"
if [[ "$CLEANUP_IMAGE" == "true" ]]; then
  # Clean up apt caches to reduce the image size
  sudo apt-get clean

  sudo rm -rf \
    $TEMPLATE_DIR \
    /var/cache/apt

  # Clean up files to reduce confusion during debug
  sudo rm -rf \
    /etc/hostname \
    /etc/machine-id \
    /etc/resolv.conf \
    /etc/ssh/ssh_host* \
    /home/ubuntu/.ssh/authorized_keys \
    /root/.ssh/authorized_keys \
    /var/lib/cloud/data \
    /var/lib/cloud/instance \
    /var/lib/cloud/instances \
    /var/lib/cloud/sem \
    /var/lib/dhclient/* \
    /var/lib/dhcp/dhclient.* \
    /var/lib/apt/history \
    /var/log/cloud-init-output.log \
    /var/log/cloud-init.log \
    /var/log/auth.log \
    /var/log/wtmp
fi

sudo touch /etc/machine-id
