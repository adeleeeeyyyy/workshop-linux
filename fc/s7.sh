#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive
echo "=== [1] install curl jq ==="
apt-get install -y curl jq 2>&1 | tail -3
curl -sI -m 8 https://pkgs.tailscale.com/stable/ | head -2

echo "=== [2] create /dev/net/tun (LXC only) ==="
mkdir -p /dev/net
[ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200
chmod 666 /dev/net/tun; ls -l /dev/net/tun

echo "=== [3] tailscale repo (trixie) ==="
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg && echo "gpg ok $(stat -c%s /usr/share/keyrings/tailscale-archive-keyring.gpg) bytes"
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list && cat /etc/apt/sources.list.d/tailscale.list
apt-get update -qq 2>&1 | tail -2
apt-get install -y tailscale 2>&1 | tail -4
tailscale version

echo "=== [4] service ==="
systemctl enable --now tailscaled 2>&1 | tail -2; sleep 4; systemctl is-active tailscaled
tailscale status 2>&1 | head -3
echo "=== [5] up without authkey -> login URL ==="
timeout 30 tailscale up --accept-dns=false --accept-routes=false 2>&1 | tail -3
echo "rc=$?"
tailscale status 2>&1 | head -3
ip -brief addr show tailscale0 2>&1
echo "=== [6] service logs ==="
journalctl -u tailscaled -n 4 --no-pager | tail -4
echo DONE
