#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

IFS=$'\n\t'

function print_help {
    echo "usage: $0 [options] <cluster-name>"
    echo "Bootstraps an instance into an EKS cluster"
    echo ""
    echo "-h,--help print this help"
    echo "--use-max-pods Sets --max-pods for the kubelet when true. (default: true)"
    echo "--b64-cluster-ca The base64 encoded cluster CA content. Only valid when used with --apiserver-endpoint. Bypasses calling \"aws eks describe-cluster\""
    echo "--apiserver-endpoint The EKS cluster API Server endpoint. Only valid when used with --b64-cluster-ca. Bypasses calling \"aws eks describe-cluster\""
    echo "--kubelet-extra-args Extra arguments to add to the kubelet. Useful for adding labels or taints."
}

POSITIONAL=()

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 1
            ;;
        --use-max-pods)
            USE_MAX_PODS="$2"
            shift
            shift
            ;;
        --b64-cluster-ca)
            B64_CLUSTER_CA=$2
            shift
            shift
            ;;
        --apiserver-endpoint)
            APISERVER_ENDPOINT=$2
            shift
            shift
            ;;
        --kubelet-extra-args)
            KUBELET_EXTRA_ARGS=$2
            shift
            shift
            ;;
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters
CLUSTER_NAME="$1"
set -u

USE_MAX_PODS="${USE_MAX_PODS:-true}"
B64_CLUSTER_CA="${B64_CLUSTER_CA:-}"
APISERVER_ENDPOINT="${APISERVER_ENDPOINT:-}"
KUBELET_EXTRA_ARGS="${KUBELET_EXTRA_ARGS:-}"

if [ -z "$CLUSTER_NAME" ]; then
    echo "CLUSTER_NAME is not defined"
    exit  1
fi

ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
AWS_DEFAULT_REGION=$(echo $ZONE | awk '{print substr($0, 1, length($0)-1)}')

### kubelet kubeconfig

CA_CERTIFICATE_DIRECTORY=/etc/kubernetes/pki
CA_CERTIFICATE_FILE_PATH=$CA_CERTIFICATE_DIRECTORY/ca.crt
mkdir -p $CA_CERTIFICATE_DIRECTORY
if [[ -z "${B64_CLUSTER_CA}" ]] && [[ -z "${APISERVER_ENDPOINT}" ]]; then
    DESCRIBE_CLUSTER_RESULT="/tmp/describe_cluster_result.txt"
    aws eks describe-cluster \
        --region=${AWS_DEFAULT_REGION} \
        --name=${CLUSTER_NAME} \
        --output=text \
        --query 'cluster.{certificateAuthorityData: certificateAuthority.data, endpoint: endpoint}' > $DESCRIBE_CLUSTER_RESULT
    B64_CLUSTER_CA=$(cat $DESCRIBE_CLUSTER_RESULT | awk '{print $1}')
    APISERVER_ENDPOINT=$(cat $DESCRIBE_CLUSTER_RESULT | awk '{print $2}')
fi

echo $B64_CLUSTER_CA | base64 -d > $CA_CERTIFICATE_FILE_PATH

kubectl config \
    --kubeconfig /var/lib/kubelet/kubeconfig \
    set-cluster \
    kubernetes \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --server=$APISERVER_ENDPOINT
sed -i s,CLUSTER_NAME,$CLUSTER_NAME,g /var/lib/kubelet/kubeconfig

### kubelet.service configuration

INTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_TYPE=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)
DNS_CLUSTER_IP=10.100.0.10
if [[ $INTERNAL_IP == 10.* ]] ; then
    DNS_CLUSTER_IP=172.20.0.10;
fi

if [[ "$USE_MAX_PODS" = "true" ]]; then
    MAX_PODS_FILE="/etc/eks/eni-max-pods.txt"
    MAX_PODS=$(grep $INSTANCE_TYPE $MAX_PODS_FILE | awk '{print $2}')
    cat <<EOF > /etc/systemd/system/kubelet.service.d/20-max-pods.conf
[Service]
Environment='KUBELET_MAX_PODS=--max-pods=$MAX_PODS'
EOF
fi

cat <<EOF > /etc/systemd/system/kubelet.service.d/10-kubelet-args.conf
[Service]
Environment='KUBELET_ARGS=--node-ip=$INTERNAL_IP --cluster-dns=$DNS_CLUSTER_IP --pod-infra-container-image=602401143452.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/eks/pause-amd64:3.1'
EOF

if [[ -n "$KUBELET_EXTRA_ARGS" ]]; then
    cat <<EOF > /etc/systemd/system/kubelet.service.d/30-kubelet-extra-args.conf
[Service]
Environment='KUBELET_EXTRA_ARGS=$KUBELET_EXTRA_ARGS'
EOF
fi

systemctl daemon-reload
systemctl enable kubelet
systemctl start kubelet
