#!/bin/bash
set -u
echo "=== [1] jail.local ==="
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip  = 198.51.100.0/24
bantime   = 10m
findtime  = 10m
maxretry  = 3

[sshd]
enabled  = true
backend  = systemd
EOF
cat /etc/fail2ban/jail.local

echo "=== [2] test filter (dry) ==="
fail2ban-client -t 2>&1 | tail -3
systemctl restart fail2ban; sleep 3; systemctl is-active fail2ban
fail2ban-client status
fail2ban-client status sshd

echo "=== [3] generate 5 failed logins (invalid user) ==="
for i in 1 2 3 4 5; do ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 nobody$i@127.0.0.1 true 2>/dev/null; done
echo "--- journal view ---"
journalctl -u ssh --since '-1 min' --no-pager | tail -6

echo "=== [4] jail status after invalid-user attempts ==="
sleep 4
fail2ban-client status sshd

echo "=== [5] generate 5 wrong-password attempts on ops (python pty) ==="
python3 - <<'PY'
import pty, os, sys
for i in range(5):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("ssh", ["ssh","-o","StrictHostKeyChecking=no","-o","PreferredAuthentications=password",
                          "-o","PubkeyAuthentication=no","-o","NumberOfPasswordPrompts=1","ops@127.0.0.1","true"])
    else:
        try:
            os.write(fd, b"WrongPass1!\n")
        except OSError:
            pass
        try: os.waitpid(pid, 0)
        except ChildProcessError: pass
        try: os.close(fd)
        except OSError: pass
print("attempts done")
PY

echo "--- journal view ---"
journalctl -u ssh --since '-1 min' --no-pager | tail -8

echo "=== [6] jail status after wrong-password attempts ==="
sleep 4
fail2ban-client status sshd
fail2ban-client get sshd banip 2>&1
echo "=== [7] nft set ==="
nft list ruleset | grep -A4 'f2b-table' | head -30
echo "=== [8] unban test ==="
fail2ban-client set sshd unbanip 127.0.0.1 2>&1
fail2ban-client status sshd
echo "DONE"
