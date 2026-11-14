#!/bin/bash
set -u
echo "=== [0] ssh restored? ==="
ls /etc/ssh/sshd_config.d/; sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|allowusers)'; cat /root/watchdog.log 2>/dev/null

echo "=== [1] ufw install ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y ufw 2>&1 | tail -5
ufw --version; dpkg -l ufw iptables nftables 2>/dev/null | grep ^ii

echo "=== [2] ufw default policy + allow 22 BEFORE enable ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw status verbose

echo "=== [3] enable ufw non-interactive ==="
ufw --force enable; echo rc=$?
ufw status verbose
echo "=== [4] nft backend check ==="
iptables -L -n 2>&1 | head -8
nft list ruleset | head -40

echo "=== [5] fail2ban install ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban 2>&1 | tail -6
fail2ban-client --version

echo "=== [6] defaults shipped ==="
ls /etc/fail2ban/jail.d/
cat /etc/fail2ban/jail.d/defaults-debian.conf 2>/dev/null
grep -nE '^(backend|banaction|ignoreip|bantime|findtime|maxretry)' /etc/fail2ban/jail.conf | head

echo "=== [7] auth.log vs journal ==="
ls -la /var/log/auth.log 2>&1; systemctl is-active systemd-journald
grep -c . /etc/fail2ban/filter.d/sshd.conf
grep -nE 'Connection closed by' /etc/fail2ban/filter.d/sshd.conf | head -5
