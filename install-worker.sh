#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

IFS=$'\n\t'

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}

################################################################################
### Packages ###################################################################
################################################################################

# Update the OS to begin with to catch up to the latest packages.
sudo apt-get update -y

sudo apt-get install -y \
    conntrack \
    ntp \
    socat \
    unzip \
    jq \
    nfs-kernel-server

sudo systemctl restart ntp.service

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

sudo pip3 install --upgrade awscli

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

################################################################################
### Logrotate ##################################################################
################################################################################

# kubelet uses journald which has built-in rotation and capped size.
# See man 5 journald.conf
sudo mv $TEMPLATE_DIR/logrotate-kube-proxy /etc/logrotate.d/kube-proxy
sudo chown root:root /etc/logrotate.d/kube-proxy/
sudo mkdir -p /var/log/journal

################################################################################
### Kubernetes #################################################################
################################################################################

sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/kubernetes
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /opt/cni/bin

CNI_VERSION=${CNI_VERSION:-"v0.6.0"}
wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-amd64-${CNI_VERSION}.tgz
wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-amd64-${CNI_VERSION}.tgz.sha512
sudo sha512sum -c cni-amd64-${CNI_VERSION}.tgz.sha512
sudo tar -xvf cni-amd64-${CNI_VERSION}.tgz -C /opt/cni/bin
rm cni-amd64-${CNI_VERSION}.tgz cni-amd64-${CNI_VERSION}.tgz.sha512

CNI_PLUGIN_VERSION=${CNI_PLUGIN_VERSION:-"v0.7.1"}
wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz
wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo sha512sum -c cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo tar -xvf cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz -C /opt/cni/bin
rm cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz cni-plugins-amd64-${CNI_PLUGIN_VERSION}.tgz.sha512

# Install kubelet and kubectl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo bash -c "cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF"
sudo apt-get update
sudo apt-get install -y kubelet=1.10.7-00 kubectl=1.10.7-00
sudo apt-mark hold kubelet kubectl

# Install aws-iam-authenticator
sudo wget https://amazon-eks.s3-us-west-2.amazonaws.com/1.10.3/2018-07-26/bin/linux/amd64/aws-iam-authenticator
sudo wget https://amazon-eks.s3-us-west-2.amazonaws.com/1.10.3/2018-07-26/bin/linux/amd64/aws-iam-authenticator.sha256
sudo sha256sum -c aws-iam-authenticator.sha256
sudo chmod +x aws-iam-authenticator
sudo mv aws-iam-authenticator /usr/bin/

sudo rm *.sha256

sudo mkdir -p /etc/kubernetes/kubelet
sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo mv $TEMPLATE_DIR/kubelet-kubeconfig /var/lib/kubelet/kubeconfig
sudo chown root:root /var/lib/kubelet/kubeconfig
sudo mv $TEMPLATE_DIR/kubelet.service /etc/systemd/system/kubelet.service
sudo chown root:root /etc/systemd/system/kubelet.service
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
    /etc/machine-id \
    /etc/ssh/ssh_host* \
    /root/.ssh/authorized_keys \
    /home/ubuntu/.ssh/authorized_keys \
    /var/log/auth.log \
    /var/log/wtmp \
    /var/lib/cloud/sem \
    /var/lib/cloud/data \
    /var/lib/cloud/instance \
    /var/lib/cloud/instances \
    /var/log/cloud-init.log \
    /var/log/cloud-init-output.log

sudo touch /etc/machine-id
