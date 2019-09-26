PACKER_BINARY ?= packer
PACKER_VARIABLES := ami_groups ami_name binary_bucket_name kubernetes_version kubernetes_build_date docker_version cni_version cni_plugin_version source_ami_id arch instance_type vpc_id subnet_id
AWS_DEFAULT_REGION ?= us-west-2

publish ?= false
date ?= $(shell date +%Y-%m-%d)
time ?= $(shell date +%s)

ifeq ($(PUBLISH), true)
override ami_groups := all
ami_name := ubuntu-EKS-$(version)-$(date)
else
ami_name := amazon-eks-ubuntu-1804-node-$(version)-$(time)
endif

kubernetes_version := $(version)
ifeq ($(version), latest)
kubernetes_version := 1.14.6
endif

arch ?= x86_64
ifeq ($(arch), arm64)
instance_type ?= a1.large
else
instance_type ?= c4.large
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
all: 1.11 1.12 1.13 1.14 latest

.PHONY: validate
validate:
    @echo "version: $(kubernetes_version)"
	$(PACKER_BINARY) validate $(foreach packerVar,$(PACKER_VARIABLES), $(if $($(packerVar)),--var $(packerVar)=$($(packerVar)),)) eks-worker-ubuntu.json

.PHONY: k8s
k8s: validate
	@echo "$(T_GREEN)Building AMI for version $(T_YELLOW)$(version)$(T_GREEN) on $(T_YELLOW)$(arch)$(T_RESET)"
	$(PACKER_BINARY) build $(foreach packerVar,$(PACKER_VARIABLES), $(if $($(packerVar)),--var $(packerVar)=$($(packerVar)),)) eks-worker-ubuntu.json

.PHONY: 1.11
1.11: validate
	$(MAKE) version=1.11.10 kubernetes_build_date=2019-08-14 k8s

.PHONY: 1.12
1.12: validate
	$(MAKE) version=1.12.10 kubernetes_build_date=2019-08-14 k8s

.PHONY: 1.13
1.13: validate
	$(MAKE) version=1.13.8 kubernetes_build_date=2019-08-14 k8s

.PHONY: 1.14
1.14: validate
	$(MAKE) version=1.14.6 kubernetes_build_date=2019-08-22 k8s

.PHONY: latest
latest: validate
	$(MAKE) version=latest kubernetes_build_date=2019-08-22 k8s

.PHONY: publish
publish: validate
	$(MAKE) PUBLISH=true all

.PHONY: publish-1.11
publish-1.11: validate
	$(MAKE) PUBLISH=true 1.11

.PHONY: publish-1.12
publish-1.12: validate
	$(MAKE) PUBLISH=true 1.12

.PHONY: publish-1.13
publish-1.13: validate
	$(MAKE) PUBLISH=true 1.13

.PHONY: publish-1.14
publish-1.13: validate
	$(MAKE) PUBLISH=true 1.14

.PHONY: publish-latest
publish-latest: validate
	$(MAKE) PUBLISH=true latest
