#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive
echo "=== [1] journalctl dasar ==="
journalctl -u hello -n 3 --no-pager
echo "--- prioritas err ---"
journalctl -p err -b --no-pager | tail -5
echo "--- sejak 10 menit ---"
journalctl --since '-10 min' -u nginx --no-pager | tail -3
echo "--- boot list ---"
journalctl --list-boots --no-pager | tail -3
echo "--- disk usage journal ---"
journalctl --disk-usage
echo "--- field terstruktur ---"
journalctl -u hello -n 1 -o json --no-pager | python3 -c 'import sys,json; d=json.loads(sys.stdin.readline()); print({k:d[k] for k in ("_PID","_COMM","SYSLOG_IDENTIFIER","PRIORITY","_SYSTEMD_UNIT") if k in d})'

echo "=== [2] /var/log ==="
ls -la /var/log | head -12
echo "--- auth log? ---"
ls -l /var/log/auth.log 2>&1
echo "--- nginx access log tail ---"
tail -2 /var/log/nginx/hello.access.log
echo "--- rsyslog status ---"
systemctl is-active rsyslog 2>&1; dpkg -l rsyslog 2>/dev/null | grep -c ^ii

echo "=== [3] audit resource ==="
apt-get install -y htop ncdu 2>&1 | tail -1
htop --version | head -2; ncdu -v 2>&1 | head -2
echo "--- df -h ---"; df -h / /var
echo "--- df -i ---"; df -i / | tail -1
echo "--- du per direktori ---"; du -xh --max-depth=1 /var 2>/dev/null | sort -h | tail -5
echo "--- ncdu non-interaktif (export) ---"; ncdu -1 -o /tmp/ncdu.json /var/log 2>&1 | tail -2; head -c 120 /tmp/ncdu.json; echo
echo "--- free ---"; free -h
echo "--- loadavg ---"; cat /proc/loadavg
echo "--- ss -tulpn ---"; ss -tulpn | sed -n '1,12p'
echo "--- ss summary ---"; ss -s | head -6
echo "--- nproc/vcpu ---"; nproc

echo "=== [4] wrk vs ab baseline ==="
wrk -t2 -c20 -d5s https://hello.lab.test/ 2>&1 | grep -E 'requests in|Requests/sec'
ab -q -n 500 -c 20 -k https://hello.lab.test/ 2>&1 | grep -E 'Requests per second|Failed|Non-2xx' | head -3
echo "=== [5] k6 availability from repo (dokumentasi saja) ==="
curl -s -o /dev/null -w 'k6_repo=%{http_code}\n' https://dl.k6.io/key.gpg
echo DONE
