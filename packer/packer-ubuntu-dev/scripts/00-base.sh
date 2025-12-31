#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get -y install vim nano htop git unattended-upgrades
sudo apt-get -y autoremove
