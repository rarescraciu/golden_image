#!/usr/bin/env bash
set -euo pipefail

# Hardening AFTER Packer connects.
# Keep password auth ON until the very end of the build if you prefer, but here we turn it OFF
# because your golden image should be key-based.

sudo sed -i 's/^\s*#\?\s*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/^\s*#\?\s*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^\s*#\?\s*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^\s*#\?\s*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

# Add a couple of sane limits
grep -q '^MaxAuthTries' /etc/ssh/sshd_config || echo 'MaxAuthTries 3' | sudo tee -a /etc/ssh/sshd_config >/dev/null
grep -q '^LoginGraceTime' /etc/ssh/sshd_config || echo 'LoginGraceTime 30' | sudo tee -a /etc/ssh/sshd_config >/dev/null

sudo systemctl restart ssh
