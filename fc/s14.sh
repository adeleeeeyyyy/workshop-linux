#!/bin/bash
set -u
echo "=== [1] netdata kickstart ==="
curl -fsSL -o /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh && echo "downloaded $(stat -c%s /tmp/netdata-kickstart.sh) bytes"
sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry 2>&1 | tail -25
echo "=== [2] service ==="
systemctl is-active netdata 2>&1; systemctl is-enabled netdata 2>&1
netdata -v 2>&1 | head -2
echo "=== [3] API ==="
sleep 5
curl -s -m 5 http://127.0.0.1:19999/api/v1/info | head -c 400; echo
ss -tlnp | grep 19999
echo "=== [4] mem pakai netdata ==="
ps -o pid,rss,comm -C netdata 2>/dev/null | head -5
free -m | head -2
echo DONE
