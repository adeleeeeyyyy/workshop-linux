#!/bin/bash
set -u
pkill -u root -f 'ops@127.0.0.1' 2>/dev/null; echo "cleanup rc=$?"
echo "=== [1] journal _COMM values for sshd lines ==="
journalctl -u ssh -o json --since '-10 min' --no-pager | python3 -c '
import sys, json, collections
c = collections.Counter()
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    c[(d.get("_COMM"), d.get("SYSLOG_IDENTIFIER"))] += 1
for k, v in c.most_common(): print(k, v)
'

echo "=== [2] current filter coverage (fail2ban-regex on journal) ==="
fail2ban-regex systemd-journal /etc/fail2ban/filter.d/sshd.conf 2>&1 | tail -12

echo "=== [3] fix journalmatch to sshd-session ==="
sed -i 's/^backend  = systemd$/backend  = systemd\njournalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd-session/' /etc/fail2ban/jail.local
cat /etc/fail2ban/jail.local
systemctl restart fail2ban; sleep 3
fail2ban-client status sshd

echo "=== [4] 4 invalid-user attempts from 127.0.0.1 ==="
for i in 1 2 3 4; do timeout 5 ssh -o BatchMode=yes -o StrictHostKeyChecking=no nobody$i@127.0.0.1 true 2>/dev/null; done
sleep 5
fail2ban-client status sshd
echo "=== [5] banned ip check + nft ==="
fail2ban-client get sshd banip 2>&1
nft list table inet f2b-table 2>&1 | head -20
echo "=== [6] can banned ip still reach ssh? ==="
timeout 8 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@127.0.0.1 true 2>&1 | tail -2; echo "ssh rc=$?"
echo "=== [7] unban ==="
fail2ban-client set sshd unbanip 127.0.0.1 2>&1
sleep 1
fail2ban-client status sshd
echo "=== [8] fail2ban log tail ==="
tail -6 /var/log/fail2ban.log
echo "DONE"
