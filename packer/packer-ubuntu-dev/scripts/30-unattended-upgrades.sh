#!/usr/bin/env bash
set -euo pipefail

sudo systemctl enable unattended-upgrades
# Make sure it's installed and configured; default Ubuntu config enables security updates.
sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true
