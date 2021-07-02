# Amazon EKS AMI Build Specification [![Build status](https://badge.buildkite.com/0dcc707973e4bc57d73d24d448d46905ca0c97d763f073cf56.svg)](https://buildkite.com/gusto/packer-ubuntu-eks-ami)

This repository contains resources and configuration scripts for building a
custom Amazon EKS AMI with [HashiCorp Packer](https://www.packer.io/) in ubuntu 18.04.
This repository is a port of the repository Amazon EKS uses to create the [official Amazon
EKS-optimized AMI](https://github.com/awslabs/amazon-eks-ami)
We will try to update this repository periodically with any new commits that are added
to the official Amazon EKS-optimized AMI.

## Setup

You must have [Packer](https://www.packer.io/) installed on your local system.
For more information, see [Installing Packer](https://www.packer.io/docs/install/index.html)
in the Packer documentation. You must also have AWS account credentials
configured so that Packer can make calls to AWS API operations on your behalf.
For more information, see [Authentication](https://www.packer.io/docs/builders/amazon.html#specifying-amazon-credentials)
in the Packer documentation.

**Note**
The default instance type to build this AMI is an `c5.large` and does not
qualify for the AWS free tier. You are charged for any instances created
when building this AMI.

## Building the AMI

A Makefile is provided to build the AMI, but it is just a small wrapper around
invoking Packer directly. You can initiate the build process by running the
following command in the root of this repository:

```bash
make
```

The Makefile runs Packer with the `eks-worker-ubuntu.json` build specification
template and the [amazon-ebs](https://www.packer.io/docs/builders/amazon-ebs.html)
builder. An instance is launched and the Packer [Shell
Provisioner](https://www.packer.io/docs/provisioners/shell.html) runs the
`install-worker.sh` script on the instance to install software and perform other
necessary configuration tasks.  Then, Packer creates an AMI from the instance
and terminates the instance after the AMI is created.

## AMI versions

We currently publish 4 versions of the AMI:
 - 1.10
 - 1.11
 - 1.12
 - latest

## Using the AMI

If you are just getting started with Amazon EKS, we recommend that you follow
the [Getting Started](https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html)
chapter in the Amazon EKS User Guide. However, if you want to use the ubuntu AMI provided
here, you will need to search for our specific AMI. 
An easy way to find it would be to use this [link](https://us-west-2.console.aws.amazon.com/ec2/v2/home?region=us-west-2#Images:visibility=public-images;ownerAlias=572074891743;name=ubuntu-EKS-latest-*;sort=desc:name)

Alternatively, in terraform you could use the following `aws_ami` resource:

```
data "aws_ami" "eks-worker" {
  filter {
    name   = "name"
    values = ["ubuntu-EKS-latest-*"]
  }

  most_recent = true
  owners      = ["572074891743"]
}
```
```
data "aws_ami" "eks-worker" {
  filter {
    name   = "name"
    values = ["ubuntu-EKS-1.11-*"]
  }

  most_recent = true
  owners      = ["572074891743"]
}
```
```
data "aws_ami" "eks-worker" {
  filter {
    name   = "name"
    values = ["ubuntu-EKS-1.10-*"]
  }

  most_recent = true
  owners      = ["572074891743"]
}
```

If you already have a cluster, and you want to launch a node group with your
new AMI, see [Launching Amazon EKS Worker Nodes](https://docs.aws.amazon.com/eks/latest/userguide/launch-workers.html)
in the Amazon EKS User Guide.
