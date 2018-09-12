KUBERNETES_VERSION ?= 1.10.3

DATE ?= $(shell date +%Y-%m-%d)

AWS_DEFAULT_REGION = us-west-2

all: ami

validate:
	packer validate eks-worker-ubuntu.json

ami: validate
	packer build eks-worker-ubuntu.json
