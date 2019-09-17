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
validate_env_set CNI_VERSION
validate_env_set CNI_PLUGIN_VERSION
validate_env_set KUBERNETES_VERSION
validate_env_set KUBERNETES_BUILD_DATE

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
sudo apt-get update -y

# It should be noted that this installs awscli 1.14, which does not contain EKS.
# We install the latest version of the awscli further down, after pip3 has been installed
sudo apt-get install -y \
    conntrack \
    chrony \
    socat \
    unzip \
    jq \
    nfs-kernel-server
#@sinneduy: we will skip this for now, it looks like it overrides ssh configs.
#ec2-instance-connect

################################################################################
### Time #######################################################################
################################################################################

# Make sure Amazon Time Sync Service starts on boot.
update-rc.d chrony defaults 80 20

# Make sure that chronyd syncs RTC clock to the kernel.
cat <<EOF | sudo tee -a /etc/chrony.conf
# This directive enables kernel synchronisation (every 11 minutes) of the
# real-time clock. Note that it can’t be used along with the 'rtcfile' directive.
rtcsync
EOF

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
  sudo apt-get install -y docker-ce
  sudo usermod -aG docker $USER
  
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
sudo chown root:root /etc/logrotate.d/kube-proxy
sudo mkdir -p /var/log/journal

################################################################################
### Kubernetes #################################################################
################################################################################

sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/kubernetes
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /opt/cni/bin

wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-${ARCH}-${CNI_VERSION}.tgz
wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-${ARCH}-${CNI_VERSION}.tgz.sha512
sudo sha512sum -c cni-${ARCH}-${CNI_VERSION}.tgz.sha512
sudo tar -xvf cni-${ARCH}-${CNI_VERSION}.tgz -C /opt/cni/bin
rm cni-${ARCH}-${CNI_VERSION}.tgz cni-${ARCH}-${CNI_VERSION}.tgz.sha512

wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz
wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo sha512sum -c cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo tar -xvf cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz -C /opt/cni/bin
rm cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz.sha512

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

# Install aws-iam-authenticator
echo "Downloading binaries from: s3://$BINARY_BUCKET_NAME"
S3_DOMAIN="s3-$BINARY_BUCKET_REGION"
if [ "$BINARY_BUCKET_REGION" = "us-east-1" ]; then
    S3_DOMAIN="s3"
fi
S3_URL_BASE="https://$BINARY_BUCKET_NAME.$S3_DOMAIN.amazonaws.com/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"
S3_PATH="s3://$BINARY_BUCKET_NAME/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"

BINARIES=(
    aws-iam-authenticator
)
for binary in ${BINARIES[*]} ; do
    # It should be noted that we diverge here:
    # Instead of checking for expected access keys, we just use wget instead
    if false; then #type "aws" > /dev/null; then
        echo "AWS cli present - using it to copy binaries from s3."
        aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary .
        aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary.sha256 .
    else
        echo "AWS cli missing - using wget to fetch binaries from s3. Note: This won't work for private bucket."
        sudo wget $S3_URL_BASE/$binary
        sudo wget $S3_URL_BASE/$binary.sha256
    fi
    sudo sha256sum -c $binary.sha256
    sudo chmod +x $binary
    sudo mv $binary /usr/bin/
done
sudo rm *.sha256

KUBELET_CONFIG=""
KUBERNETES_MINOR_VERSION=${KUBERNETES_VERSION%.*}
if [ "$KUBERNETES_MINOR_VERSION" = "1.10" ] || [ "$KUBERNETES_MINOR_VERSION" = "1.11" ]; then
    KUBELET_CONFIG=kubelet-config.json
else
    # For newer versions use this config to fix https://github.com/kubernetes/kubernetes/issues/74412.
    KUBELET_CONFIG=kubelet-config-with-secret-polling.json
fi

sudo mkdir -p /etc/kubernetes/kubelet
sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo mv $TEMPLATE_DIR/kubelet-kubeconfig /var/lib/kubelet/kubeconfig
sudo chown root:root /var/lib/kubelet/kubeconfig
if [ "$KUBERNETES_MINOR_VERSION" = "1.14" ]; then
    sudo mv $TEMPLATE_DIR/1.14/kubelet.service /etc/systemd/system/kubelet.service
else
    sudo mv $TEMPLATE_DIR/kubelet.service /etc/systemd/system/kubelet.service
fi
sudo chown root:root /etc/systemd/system/kubelet.service
sudo mv $TEMPLATE_DIR/$KUBELET_CONFIG /etc/kubernetes/kubelet/kubelet-config.json
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

################################################################################
### AMI Metadata ###############################################################
################################################################################

BASE_AMI_ID=$(curl -s  http://169.254.169.254/latest/meta-data/ami-id)
cat <<EOF > /tmp/release
BASE_AMI_ID="$BASE_AMI_ID"
BUILD_TIME="$(date)"
BUILD_KERNEL="$(uname -r)"
AMI_NAME="$AMI_NAME"
ARCH="$(uname -m)"
EOF
sudo mv /tmp/release /etc/eks/release
sudo chown root:root /etc/eks/*

################################################################################
### Cleanup ####################################################################
################################################################################

# Clean up apt caches to reduce the image size
sudo apt-get clean

sudo rm -rf \
    $TEMPLATE_DIR  \
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

sudo touch /etc/machine-id
