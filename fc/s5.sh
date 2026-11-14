#!/bin/bash
# A/B test: default journalmatch vs sshd-session journalmatch, attacks from 172.23.3.1
VM=root@172.23.1.88
ATK=root@172.23.3.1
jm() { ssh $VM "sed -i 's|^journalmatch.*|journalmatch = $1|' /etc/fail2ban/jail.local; systemctl restart fail2ban; sleep 3; fail2ban-client status sshd | grep -E 'Journal matches|Total failed|Currently banned'"; }
attack() { ssh $ATK 'for i in 1 2 3 4; do timeout 5 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 baduser$i@172.23.1.88 true 2>/dev/null; done; echo attacked'; }

echo "########## A: default journalmatch (_COMM=sshd) ##########"
jm '_SYSTEMD_UNIT=ssh.service + _COMM=sshd'
attack
sleep 5
ssh $VM "fail2ban-client status sshd | grep -E 'Total failed|Currently banned|Banned IP'; tail -4 /var/log/fail2ban.log"

echo "########## B: journalmatch (_COMM=sshd-session) ##########"
jm '_SYSTEMD_UNIT=ssh.service + _COMM=sshd-session'
attack
sleep 5
ssh $VM "fail2ban-client status sshd; fail2ban-client get sshd banip; echo '--- nft ---'; nft list table inet f2b-table 2>&1 | head -25; tail -4 /var/log/fail2ban.log"

echo "########## C: blocked attacker test ##########"
ssh $ATK 'timeout 6 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=4 ops@172.23.1.88 true 2>&1 | tail -2; echo "atk_ssh_rc=$?"'
echo "########## D: unban ##########"
ssh $VM "fail2ban-client set sshd unbanip 172.23.3.1; sleep 1; fail2ban-client status sshd | grep -E 'Currently banned|Banned IP'"
ssh $ATK 'timeout 6 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=4 baduser9@172.23.1.88 true 2>&1 | tail -1; echo "after_unban_rc=$?"'
