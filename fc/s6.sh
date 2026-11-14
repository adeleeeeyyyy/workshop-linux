#!/bin/bash
set -u
echo "=== [1] restore default jail.local ==="
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 198.51.100.0/24
bantime  = 10m
findtime = 10m
maxretry = 3

[sshd]
enabled = true
backend = systemd
EOF
fail2ban-client -t 2>&1 | tail -2
systemctl restart fail2ban; sleep 2; fail2ban-client status sshd | head -12

echo "=== [2] environment for tailscale/wireguard ==="
ls -l /dev/net/tun 2>&1
head -3 /proc/net/dev | cut -c1-60
modprobe wireguard 2>&1; echo "modprobe wg rc=$?"
curl -sI -m 8 https://pkgs.tailscale.com/stable/ | head -3

echo "=== [3] tailscale install (official repo) ==="
export DEBIAN_FRONTEND=noninteractive
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg 2>&1 | tail -2
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list 2>&1 | tail -2
cat /etc/apt/sources.list.d/tailscale.list
apt-get update -qq 2>&1 | tail -2
apt-get install -y tailscale 2>&1 | tail -5
tailscale version

echo "=== [4] enable + status ==="
systemctl enable --now tailscaled; sleep 3; systemctl is-active tailscaled
tailscale status 2>&1 | head -5
tailscale ip -4 2>&1 | head -2

echo "=== [5] tailscale up without key (expected: login URL) ==="
timeout 25 tailscale up --accept-dns=false --timeout=10s 2>&1 | tail -4
echo "=== [6] interfaces ==="
ip -brief addr show 2>&1
echo "DONE"
