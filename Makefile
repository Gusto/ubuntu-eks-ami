DOCKER_VERSION ?= 18.06
KUBERNETES_BUILD_DATE ?= 2019-03-27
CNI_VERSION ?= v0.6.0
CNI_PLUGIN_VERSION ?= v0.7.5
ARCH ?= x86_64
BINARY_BUCKET_NAME ?= amazon-eks
SOURCE_AMI_OWNERS ?= 137112412989
PUBLISH ?= false
DATE ?= $(shell date +%Y-%m-%d)
TIME ?= $(shell date +%s)

PACKER_BINARY ?= packer
AWS_BINARY ?= aws

ifeq ($(PUBLISH), true)
override AMI_GROUPS := all
AMI_NAME := ubuntu-EKS-$(VERSION)-$(DATE)
else
AMI_NAME := amazon-eks-ubuntu-1804-node-$(VERSION)-$(TIME)
endif

ifeq ($(VERSION), latest)
override VERSION := 1.12.7
endif

ifeq ($(ARCH), arm64)
INSTANCE_TYPE ?= a1.large
else
INSTANCE_TYPE ?= c5.large
endif


AWS_DEFAULT_REGION ?= us-west-2
ifndef VPC_ID
$(error VPC_ID is not set)
endif
ifndef SUBNET_ID
$(error SUBNET_ID is not set)
endif

T_RED := \e[0;31m
T_GREEN := \e[0;32m
T_YELLOW := \e[0;33m
T_RESET := \e[0m

.PHONY: all
all: 1.10 1.11 1.12 latest

.PHONY: validate
validate:
	$(PACKER_BINARY) validate \
		-var instance_type=$(INSTANCE_TYPE) \
		eks-worker-ubuntu.json

.PHONY: k8s
k8s: validate
#   @sinneduy: I am making a call to not include this - I don't believe this is necessary since you can specify the architecture inside eks-worker-ubuntu.json 
#   See (https://github.com/awslabs/amazon-eks-ami/pull/250/files) for original Pull Request
#   https://github.com/awslabs/amazon-eks-ami/pull/250/files#r285781524

#    @echo "$(T_GREEN)Building AMI for version $(T_YELLOW)$(VERSION)$(T_GREEN) on $(T_YELLOW)$(ARCH)$(T_RESET)"
#   $(eval SOURCE_AMI_ID := $(shell $(AWS_BINARY) ec2 describe-images \
#     --output text \
#     --filters \
#       Name=owner-id,Values=$(SOURCE_AMI_OWNERS) \
#       Name=virtualization-type,Values=hvm \
#       Name=root-device-type,Values=ebs \
#       Name=name,Values=amzn2-ami-minimal-hvm-* \
#       Name=architecture,Values=$(ARCH) \
#       Name=state,Values=available \
#     --query 'max_by(Images[], &CreationDate).ImageId'))
#   @if [ -z "$(SOURCE_AMI_ID)" ]; then\
#   	echo "$(T_RED)Failed to find candidate AMI!$(T_RESET)"; \
#   	exit 1; \
#   fi
	$(PACKER_BINARY) build \
        -var instance_type=$(INSTANCE_TYPE) \
		-var kubernetes_version=$(VERSION) \
		-var kubernetes_build_date=$(KUBERNETES_BUILD_DATE) \
		-var arch=$(ARCH) \
		-var binary_bucket_name=$(BINARY_BUCKET_NAME) \
		-var cni_version=$(CNI_VERSION) \
		-var cni_plugin_version=$(CNI_PLUGIN_VERSION) \
		-var docker_version=$(DOCKER_VERSION) \
		-var vpc_id=$(VPC_ID) \
		-var subnet_id=$(SUBNET_ID) \
		-var ami_groups=$(AMI_GROUPS) \
		-var ami_name=$(AMI_NAME) \
		eks-worker-ubuntu.json

.PHONY: 1.10
1.10: validate
	$(MAKE) VERSION=1.10.13 k8s

.PHONY: 1.11
1.11: validate
	$(MAKE) VERSION=1.11.9 k8s

.PHONY: 1.12
1.12: validate
	$(MAKE) VERSION=1.12.7 k8s

.PHONY: latest
latest: validate
	$(MAKE) VERSION=latest k8s

.PHONY: publish
publish: validate
	$(MAKE) PUBLISH=true all

.PHONY: publish-1.10
publish-1.10: validate
	$(MAKE) PUBLISH=true 1.10

.PHONY: publish-1.11
publish-1.11: validate
	$(MAKE) PUBLISH=true 1.11

.PHONY: publish-1.12
publish-1.12: validate
	$(MAKE) PUBLISH=true 1.12

.PHONY: publish-latest
publish-latest: validate
	$(MAKE) PUBLISH=true latest
