#!/usr/bin/env bash
set -euo pipefail

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw --force enable

sudo systemctl enable fail2ban
sudo tee /etc/fail2ban/jail.d/ssh-hard.conf >/dev/null << 'EOF'
[sshd]
enabled = true
maxretry = 3
findtime = 10m
bantime = 1h
EOF
sudo systemctl restart fail2ban
