#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

sudo apt-get update -y
sudo apt-get -y dist-upgrade

sudo reboot
