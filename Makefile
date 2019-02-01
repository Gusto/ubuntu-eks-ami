KUBERNETES_VERSION ?= 1.10.3

DATE ?= $(shell date +%Y-%m-%d)

AWS_DEFAULT_REGION = us-west-2

.PHONY: all validate ami 1.11 1.10

all: 1.11

validate:
	packer validate eks-worker-ubuntu.json

1.10: validate
	packer build \
      -var kube_version=1.10.11\
      eks-worker-ubuntu.json

1.11: validate
	packer build \
      -var kube_version=1.11.5\
      eks-worker-ubuntu.json
