#!/bin/bash
set -e

# Re-enable cloud-init (installer disables it by default)
sudo rm -f /etc/cloud/cloud-init.disabled

# Reset cloud-init state so clones behave like first boot
sudo cloud-init clean --logs

# Ensure unique identity per clone
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
