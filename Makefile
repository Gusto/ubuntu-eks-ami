PACKER_BINARY ?= packer
PACKER_VARIABLES := aws_region ami_name ami_groups binary_bucket_name binary_bucket_region kubernetes_version kubernetes_build_date kernel_version docker_version containerd_version cni_plugin_version runc_version source_ami_id source_ami_owners source_ami_filter_name arch instance_type security_group_id vpc_id subnet_id pull_cni_from_github sonobuoy_e2e_registry

AWS_DEFAULT_REGION ?= us-west-2

aws_region ?= $(AWS_DEFAULT_REGION)
binary_bucket_region ?= $(AWS_DEFAULT_REGION)
pull_cni_from_github ?= true

publish ?= false
date ?= $(shell date +%Y-%m-%d)
time ?= $(shell date +%s)

ifeq ($(PUBLISH), true)
override ami_groups := all
endif

kubernetes_version := $(version)
ifeq ($(version), latest)
kubernetes_version := 1.16.12
endif

arch ?= x86_64
ifeq ($(arch), arm64)
    ifeq ($(PUBLISH), true)
    ami_name := ubuntu-EKS-arm64-$(version)-$(date)
    else
    ami_name := amazon-eks-arm64-ubuntu-1804-node-$(version)-$(time)
    endif
instance_type ?= m6g.large
else
	ifeq ($(PUBLISH), true)
    ami_name := ubuntu-EKS-$(version)-$(date)
    else
    ami_name := amazon-eks-ubuntu-1804-node-$(version)-$(time)
    endif
instance_type ?= m4.large
endif

ifndef vpc_id
$(error vpc_id is not set)
endif
ifndef subnet_id
$(error subnet_id is not set)
endif

T_RED := \e[0;31m
T_GREEN := \e[0;32m
T_YELLOW := \e[0;33m
T_RESET := \e[0m

.PHONY: all
all: 1.17 1.18 1.19 1.20

.PHONY: validate
validate:
    @echo "version: $(kubernetes_version)"
	$(PACKER_BINARY) validate $(foreach packerVar,$(PACKER_VARIABLES), $(if $($(packerVar)),--var $(packerVar)='$($(packerVar))',)) eks-worker-ubuntu.json

.PHONY: k8s
k8s: validate
	@echo "$(T_GREEN)Building AMI for version $(T_YELLOW)$(version)$(T_GREEN) on $(T_YELLOW)$(arch)$(T_RESET)"
	$(PACKER_BINARY) build $(foreach packerVar,$(PACKER_VARIABLES), $(if $($(packerVar)),--var $(packerVar)='$($(packerVar))',)) eks-worker-ubuntu.json

.PHONY: 1.17
1.17: validate
	$(MAKE) k8s version=1.17.12 kubernetes_build_date=2020-11-02 pull_cni_from_github=true

.PHONY: 1.18
1.18:
	$(MAKE) k8s version=1.18.9 kubernetes_build_date=2020-11-02 pull_cni_from_github=true

.PHONY: 1.19
1.19:
	$(MAKE) k8s version=1.19.6 kubernetes_build_date=2021-01-05 pull_cni_from_github=true

.PHONY: 1.20
1.20:
	$(MAKE) k8s version=1.20.4 kubernetes_build_date=2021-04-12 pull_cni_from_github=true

.PHONY: publish
publish: validate
	$(MAKE) PUBLISH=true all

.PHONY: publish-1.17
publish-1.17: validate
	$(MAKE) PUBLISH=true 1.17

.PHONY: publish-1.18
publish-1.18: validate
	$(MAKE) PUBLISH=true 1.18

.PHONY: publish-1.19
publish-1.19: validate
	$(MAKE) PUBLISH=true 1.19

.PHONY: publish-1.20
publish-1.20: validate
	$(MAKE) PUBLISH=true 1.20

