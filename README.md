# Workshop Linux: Server Sudah Jadi, Terus Apa?

Modul praktik lanjutan untuk admin server Linux. Materi workshop pertama
(Bangun Server Linux dari 0) tidak wajib diingat: setiap sub-topik di sini
berdiri sendiri.

## Cara pakai

- Setiap sub-topik bisa dijalankan di VM yang baru di-install.
- Tidak ada urutan wajib. Ambil yang dibutuhkan.
- Tiap sub-topik berisi: hasil yang diharapkan, prasyarat, perintah, verifikasi,
  error umum, dan jebakan.
- Perintah memakai placeholder. Ganti sebelum dijalankan.

| Placeholder | Arti | Contoh |
|---|---|---|
| `<user>` | nama user admin | `adly` |
| `<IP-VM>` | IP VM | `10.10.10.20` |
| `<domain>` | nama host aplikasi | `app.lab.test` |
| `<path>` | direktori yang dibackup | `/etc/nginx` |
| `<subnet-admin>` | subnet PC admin | `192.168.20.0/24` |

Semua perintah sebagai `root`. OS acuan Debian 13 (trixie). Ubuntu 24.04
sebagian besar sama, kecuali nama paket dan socket activation SSH.

## Daftar modul

| Modul | Sub-topik | Waktu |
|---|---|---|
| [1. Security Hardening](modul/01-hardening/README.md) | user dan sudo, SSH key, UFW, Fail2Ban, Tailscale | 90 menit |
| [2. Web dan Performance](modul/02-web/README.md) | systemd service, nginx reverse proxy, HTTPS, gzip, cache, rate limit | 95 menit |
| [3. Monitoring dan Stress Test](modul/03-monitoring/README.md) | journalctl, audit resource, Netdata, wrk | 70 menit |
| [4. Backup, Alerting, Automation](modul/04-backup/README.md) | update otomatis, script backup, cron, restore, notifikasi | 80 menit |

Total 5 jam 35 menit. Satu hari dengan istirahat.

## Prasyarat umum

- VM Debian 13, akses `root` lewat console atau SSH.
- Repo apt aktif dan VM bisa internet.
- Satu mesin kedua untuk menguji firewall, fail2ban, dan load test.

Sub-topik yang butuh akun pihak ketiga: Tailscale (1.5), Let's Encrypt dan
Cloudflare Tunnel (2.3), bot Telegram atau webhook Discord (4.4). Ketiganya
bertanda DOKUMENTASI karena tidak bisa diuji tanpa akun.

## Cheat sheet

```bash
# akses
adduser <user>; usermod -aG sudo <user>; id <user>; sudo -l -U <user>
ssh-keygen -t ed25519 -f ~/.ssh/lab; ssh-copy-id -i ~/.ssh/lab.pub <user>@<IP-VM>
sshd -t; sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|allowusers'
systemctl restart ssh

# firewall dan brute force
ufw default deny incoming; ufw allow 22/tcp; ufw --force enable; ufw status verbose
fail2ban-client status sshd; fail2ban-client set sshd unbanip <IP>

# tunnel
tailscale up --accept-dns=false; tailscale status; tailscale ip -4

# service
systemctl daemon-reload; systemctl enable --now demo; systemctl restart demo
systemctl show -p User -p MainPID -p NRestarts --value demo
journalctl -u demo -n 50 --no-pager

# nginx
nginx -t && systemctl reload nginx
nginx -T | grep -E 'proxy_pass|limit_req|proxy_cache'
ss -tlnp | grep -E ':80|:443'
curl -sk -D- -o /dev/null https://<domain>/ | grep -i x-cache-status
curl -sk -H 'Accept-Encoding: gzip' -o /dev/null -w '%{size_download}\n' https://<domain>/big.txt

# TLS
openssl req -x509 -nodes -newkey rsa:2048 -days 365 -keyout <k>.key -out <c>.crt \
  -subj "/CN=<domain>" -addext "subjectAltName=DNS:<domain>"
openssl x509 -in <c>.crt -noout -subject -dates -ext subjectAltName
certbot --nginx -d <domain>; certbot renew --dry-run

# log dan resource
journalctl -u <unit> -n 50 --no-pager; journalctl -p err -b; journalctl --disk-usage
journalctl --vacuum-size=200M
df -h /; df -i /; du -xh --max-depth=1 /var | sort -h | tail; free -h
ss -tulpn; ss -s; cat /proc/loadavg; nproc

# beban
wrk -t2 -c20 -d5s --latency http://<target>/
ab -q -n 500 -c20 -k http://<target>/

# backup
unattended-upgrade --dry-run; systemctl list-timers 'apt*'
/usr/local/bin/backup.sh; sha256sum -c /var/backups/app/*.sha256
tar tzf /var/backups/app/app-*.tar.gz
tar xzf <arsip> -C / <path-relatif>
journalctl -u cron -n 20 --no-pager | grep CMD
env -i /bin/bash -c '/usr/local/bin/backup.sh'

# alert
/usr/local/bin/notify.sh "pesan uji"
/usr/local/bin/check-disk.sh
```
