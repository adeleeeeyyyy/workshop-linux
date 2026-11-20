# Workshop Linux: Server Sudah Jadi, Terus Apa?

Modul praktik lanjutan untuk admin server Linux. Materi workshop pertama
(Bangun Server Linux dari 0) tidak wajib diingat: setiap sub-topik di sini
berdiri sendiri.

## Cara pakai

- Setiap sub-topik bisa dijalankan di VM yang baru di-install.
- Tidak ada urutan wajib. Ambil yang dibutuhkan. Satu pengecualian ringan:
  modul 2 memakai pemetaan `app.local` di PC (bagian 2.0), kerjakan sekali.
- Tiap sub-topik berisi: hasil yang diharapkan, paket yang dipasang, prasyarat,
  langkah, verifikasi, error umum, dan jebakan.
- Konfigurasi tidak ditulis lewat perintah `echo`, `sed`, atau heredoc.
  Tiap konfigurasi tampil sebagai **path file** dan **isi file**. Anda membuka
  file itu sendiri, menulis isinya, dan mencoba hasilnya.

Cara mengedit file di VM:

```bash
nano /path/ke/file
```

Simpan dengan `Ctrl+O` lalu `Enter`, keluar dengan `Ctrl+X`. Tempel teks di
terminal SSH dengan klik kanan (Windows Terminal) atau `Ctrl+Shift+V`.

## Dua tempat menjalankan perintah

Setiap blok perintah diberi label tempatnya:

- **[Server]**: di VM, sebagai `root` (login root atau `su -`).
- **[PC Windows]**: di PowerShell pada PC peserta, Windows 10 atau 11.

Cek OpenSSH client di Windows: `ssh -V`. Kalau tidak ada, pasang dari
PowerShell Administrator:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Padanan untuk peserta Linux atau macOS:

| Keperluan | Windows (PowerShell) | Linux / macOS |
|---|---|---|
| Path key SSH | `$env:USERPROFILE\.ssh\lab` | `~/.ssh/lab` |
| Tampilkan public key | `type $env:USERPROFILE\.ssh\lab.pub` | `cat ~/.ssh/lab.pub` |
| Pasang public key ke server | tempel manual ke `authorized_keys` | `ssh-copy-id` atau tempel manual |
| HTTP dari terminal | `curl.exe` (bukan `curl`, itu alias) | `curl` |
| Buang output | `-o NUL` | `-o /dev/null` |
| Tes port | `Test-NetConnection <IP-VM> -Port 22` | `nc -zv <IP-VM> 22` |
| File hosts | `C:\Windows\System32\drivers\etc\hosts` (Administrator) | `/etc/hosts` (`sudo`) |
| Bersihkan cache DNS | `ipconfig /flushdns` | tergantung distro atau macOS |
| Saring output | `Select-String` | `grep` |
| Ulangi perintah | `foreach ($i in 1..4) { ... }` | `for i in 1 2 3 4; do ...; done` |

## Placeholder

| Placeholder | Arti | Contoh |
|---|---|---|
| `<user>` | nama user admin | `adly` |
| `<IP-VM>` | IP VM | `10.10.10.20` |
| `<IP-PC>` | IP PC peserta | `192.168.20.5` |
| `<subnet-admin>` | subnet PC peserta | `192.168.20.0/24` |

Domain lab selalu `app.local` dan ditulis apa adanya. Ganti placeholder
sebelum perintah dijalankan.

Semua perintah server sebagai `root`. OS acuan Debian 13 (trixie). Ubuntu 24.04
sebagian besar sama, kecuali nama paket dan socket activation SSH.

## Paket yang dibutuhkan

Tiap sub-topik menyebut paketnya sendiri di bagian **Paket**, lengkap dengan
perintah pasang. Supaya tidak berhenti di tengah lab, Anda juga bisa memasang
semuanya sekali di awal:

```bash
apt-get update
apt-get install -y nano curl sudo adduser openssh-server ufw fail2ban \
  nginx python3 openssl wrk apache2-utils htop ncdu \
  unattended-upgrades cron
```

| Modul | Paket |
|---|---|
| 1. Security Hardening | `sudo`, `adduser`, `openssh-server`, `ufw`, `fail2ban`, `nginx` (contoh di 1.5) |
| 2. Web dan Performance | `nginx`, `python3`, `openssl`, `curl`, `wrk`, `apache2-utils` |
| 3. Monitoring dan Stress Test | `nginx`, `htop`, `ncdu`, `curl`, `wrk`, `apache2-utils`, `python3`; Netdata lewat script resmi |
| 4. Backup, Alerting, Automation | `unattended-upgrades`, `cron`, `curl`, `nginx` |

## Daftar modul

| Modul | Sub-topik |
|---|---|
| [1. Security Hardening](modul/01-hardening/README.md) | user dan sudo, SSH key, UFW, Fail2Ban, kontrol akses native (SSH, UFW per sumber, sudo) |
| [2. Web dan Performance](modul/02-web/README.md) | hosts `app.local` di PC, systemd service, nginx reverse proxy, HTTPS self-signed, gzip, cache, rate limit |
| [3. Monitoring dan Stress Test](modul/03-monitoring/README.md) | journalctl, audit resource, Netdata, wrk |
| [4. Backup, Alerting, Automation](modul/04-backup/README.md) | update otomatis, backup file dengan tar, cron dan restore, alert Telegram (boot dan shutdown, nginx mati, login SSH, disk) |

## Prasyarat umum

- VM Debian 13, akses `root` lewat console atau SSH.
- Repo apt aktif dan VM bisa internet.
- PC peserta dengan PowerShell dan OpenSSH client, satu jaringan dengan VM.

Satu-satunya sub-topik yang butuh akun pihak ketiga: bot Telegram (4.4). Bagian
yang ditandai "demo instruktur" hanya ditampilkan, tidak dijalankan peserta.

## Cheat sheet

Di VM ([Server]):

```bash
# akses
adduser <user>; usermod -aG sudo <user>; id <user>; sudo -l -U <user>
sshd -t; sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|allowusers|allowgroups'
sshd -T -C user=<user>,host=pc,addr=<IP-PC> | grep -Ei 'allowusers|allowtcpforwarding'
systemctl restart ssh
visudo -f /etc/sudoers.d/<nama-file>

# firewall dan brute force
ufw default deny incoming; ufw allow from <subnet-admin> to any port 22 proto tcp
ufw --force enable; ufw status numbered
fail2ban-client status sshd; fail2ban-client set sshd unbanip <IP-PC>

# service
systemctl daemon-reload; systemctl enable --now demo; systemctl restart demo
systemctl show -p User -p MainPID -p NRestarts --value demo
journalctl -u demo -n 50 --no-pager

# nginx
nginx -t && systemctl reload nginx
nginx -T | grep -E 'proxy_pass|limit_req|proxy_cache'
ss -tlnp | grep -E ':80|:443'

# TLS self-signed
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /etc/ssl/private/app.local.key -out /etc/ssl/certs/app.local.crt \
  -subj "/CN=app.local" -addext "subjectAltName=DNS:app.local"
openssl x509 -in /etc/ssl/certs/app.local.crt -noout -subject -dates -ext subjectAltName

# log dan resource
journalctl -u <unit> -n 50 --no-pager; journalctl -p err -b; journalctl --disk-usage
journalctl --vacuum-size=200M
df -h /; df -i /; du -xh --max-depth=1 /var | sort -h | tail; free -h
ss -tulpn; ss -s; cat /proc/loadavg; nproc

# beban
wrk -t2 -c20 -d5s --latency http://127.0.0.1:8080/big.txt
ab -q -n 500 -c20 -k http://127.0.0.1:8080/big.txt

# backup
/usr/local/bin/backup-web.sh; ls -la /var/backups/web
tar tzf /var/backups/web/web-*.tar.gz
tar xzf <arsip> -C / <path-relatif>
journalctl -u cron -n 20 --no-pager | grep CMD
env -i /bin/bash -c '/usr/local/bin/backup-web.sh'

# alert
/usr/local/bin/notify.sh "pesan uji"
systemctl status alert-boot --no-pager
systemctl stop nginx; systemctl start nginx
THRESHOLD=1 /usr/local/bin/check-disk.sh
```

Di PC ([PC Windows], PowerShell):

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\lab
type $env:USERPROFILE\.ssh\lab.pub
ssh -i $env:USERPROFILE\.ssh\lab <user>@<IP-VM>
Test-NetConnection <IP-VM> -Port 22

ipconfig /flushdns; ping app.local
curl.exe -s http://app.local/
curl.exe -k -s https://app.local/
curl.exe -s -H 'Accept-Encoding: gzip' -o NUL -w 'gzip=%{size_download}\n' http://app.local/big.txt
1..3 | ForEach-Object { curl.exe -s -D - -o NUL http://app.local/cached/ | Select-String x-cache-status }
```
