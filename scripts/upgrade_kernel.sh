#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

sudo apt-get update -y
sudo apt-get -y dist-upgrade

# The latest version of the amazon eks ami allows for the user to choose a kernel version
# We are not supporting this capability, so that code has been left out of this file

sudo reboot
