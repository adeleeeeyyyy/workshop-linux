#!/bin/bash
set -u
echo "=== [1] tailscaled in userspace mode (LXC workaround) ==="
nohup tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock > /var/log/tailscaled-us.log 2>&1 &
sleep 6
tailscale status 2>&1 | head -3
echo "=== [2] tailscale up -> login URL ==="
timeout 20 tailscale up --accept-dns=false 2>&1 | tail -3
echo "=== [3] status after up ==="
tailscale status 2>&1 | head -3
echo "=== [4] log ==="
tail -5 /var/log/tailscaled-us.log
echo "=== [5] stop userspace daemon ==="
pkill -f 'tailscaled --tun=userspace-networking'; sleep 2; pgrep -a tailscaled || echo "stopped"
echo DONE
