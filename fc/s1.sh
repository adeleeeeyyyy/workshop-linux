#!/bin/bash
# topic 1.1 + 1.2 fact-check  (self-restoring so we never lose root access)
set -u
echo "=== [1] apt install sudo ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y sudo 2>&1 | tail -4

echo "=== [2] adduser ops ==="
adduser --disabled-password --gecos "" ops 2>&1 | tail -6

echo "=== [3] set password ops ==="
echo 'ops:Lab2026!' | chpasswd; echo "chpasswd rc=$?"

echo "=== [4] usermod -aG sudo ops ==="
usermod -aG sudo ops; echo "usermod rc=$?"

echo "=== [5] id ops / getent group sudo ==="
id ops; getent group sudo

echo "=== [6] sudo -l -U ops ==="
sudo -l -U ops

echo "=== [7] sudoers %sudo line ==="
grep -n '^%sudo' /etc/sudoers

echo "=== [8] SSH key for ops ==="
mkdir -p /home/ops/.ssh
[ -f /root/.ssh/ops_testkey ] || ssh-keygen -t ed25519 -N '' -C 'ops@lab' -f /root/.ssh/ops_testkey >/dev/null
cat /root/.ssh/ops_testkey.pub > /home/ops/.ssh/authorized_keys
chown -R ops:ops /home/ops/.ssh; chmod 700 /home/ops/.ssh; chmod 600 /home/ops/.ssh/authorized_keys
ls -la /home/ops/.ssh

echo "=== [9] write hardening conf ==="
cp -a /etc/ssh/sshd_config.d /root/sshd_config.d.bak
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers ops
EOF
cat /etc/ssh/sshd_config.d/99-hardening.conf
sshd -t; echo "sshd -t rc=$?"
echo "=== [10] sshd -T effective (pre-restart) ==="
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractive|pubkeyauthentication|maxauthtries|allowusers|port)'

echo "=== [11] watchdog: auto-revert in 30s ==="
nohup bash -c 'sleep 30; rm -f /etc/ssh/sshd_config.d/99-hardening.conf; systemctl restart ssh; echo reverted-$(date -u +%T) >> /root/watchdog.log' >/dev/null 2>&1 &
echo watchdog pid=$!
systemctl restart ssh; sleep 1; systemctl is-active ssh

echo "=== [12] ssh as ops with key ==="
ssh -i /root/.ssh/ops_testkey -o StrictHostKeyChecking=no -o BatchMode=yes ops@172.23.1.88 'id' 2>&1 | tail -2
echo "=== [13] ssh as root with key (must be denied) ==="
ssh -i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 'id' 2>&1 | tail -2
echo "=== [14] ssh as ops with PASSWORD (must be denied) ==="
ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o PreferredAuthentications=password ops@127.0.0.1 'id' 2>&1 | tail -2
echo "=== [15] auth.log present? ==="
ls -la /var/log/auth.log 2>&1
echo "=== [16] journal auth entries ==="
journalctl -u ssh -n 5 --no-pager | tail -5
echo "DONE"
