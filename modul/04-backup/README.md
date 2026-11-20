# Modul 4: Backup, Alerting & Automation

Setiap sub-topik berdiri sendiri. Tidak ada prasyarat dari modul lain.

Konvensi:
- `<user>` nama user admin, `<IP-VM>` IP VM, `<IP-PC>` IP PC Anda.
- Label **[Server]** dijalankan di VM sebagai `root`. Label **[PC Windows]**
  dijalankan di PowerShell Windows 10/11 (padanan Linux atau macOS ada di
  README utama).
- File konfigurasi dan script ditulis sebagai `File: <path>` lalu isinya. Edit
  sendiri dengan `nano <path>`, simpan `Ctrl+O` `Enter`, keluar `Ctrl+X`.
- OS acuan Debian 13.1, cron 3.0pl1, systemd 257.

---

## 4.1 Update keamanan otomatis

Hasil: patch keamanan terpasang sendiri tiap hari, tanpa `apt upgrade` manual.

Paket: `unattended-upgrades`.

```bash
apt-get install -y unattended-upgrades
```

Prasyarat: root, repo apt aktif.

Aktifkan jadwal. Tanpa dua baris ini paketnya terpasang tetapi tidak jalan.

File: `/etc/apt/apt.conf.d/20auto-upgrades`

```text
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

```bash
systemctl restart unattended-upgrades
```

Verifikasi:

```bash
apt-config dump APT::Periodic::Update-Package-Lists APT::Periodic::Unattended-Upgrade
systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer

# lihat paket yang AKAN di-upgrade, tanpa menjalankannya
unattended-upgrade --dry-run
tail -5 /var/log/unattended-upgrades/unattended-upgrades.log
```

Log berisi baris `Packages that will be upgraded: ...` dan `All upgrades
installed`. Itu dasar audit: apa yang berubah semalam.

Cek origin yang diizinkan:

```bash
grep -vE '^\s*(//|$)' /etc/apt/apt.conf.d/50unattended-upgrades | head -12
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `--dry-run` tidak melakukan apa pun | `20auto-upgrades` tidak ada atau bernilai 0 | periksa isi file itu, lalu `apt-config dump` |
| Upgrade tidak jalan pada jadwal | timer tidak aktif | `systemctl enable --now apt-daily.timer apt-daily-upgrade.timer` |
| Butuh reboot setelah update | kernel atau libc berubah | `Unattended-Upgrade::Automatic-Reboot "true";` dan set jamnya, atau reboot manual |
| Email laporan tidak masuk | tidak ada MTA | baca file log, atau pakai alert Telegram (4.4) |

Jebakan:
- Debian hanya mengambil origin `label=Debian` dan `Debian-Security`. Ubuntu
  memakai pola berbeda. Jangan salin config antar distro.
- Kernel baru tidak aktif sebelum reboot. Catat kebutuhan reboot, jangan
  mengaktifkan auto-reboot di server produksi tanpa jendela maintenance.
- `--dry-run` tetap menulis log. Jangan bingung melihat entri baru.

---

## 4.2 Backup file dengan tar

Hasil: satu script yang mengarsipkan konfigurasi nginx dan isi situs, lalu
menghapus arsip yang lebih tua dari 7 hari.

Paket: `nginx` (hanya sebagai sumber data yang dibackup). `tar` dan `find`
sudah ada di Debian.

```bash
apt-get install -y nginx
```

Prasyarat: root. Siapkan satu file situs contoh:

```bash
mkdir -p /srv/site
nano /srv/site/index.html
```

File: `/srv/site/index.html`

```text
halaman penting
```

**Langkah 1. Backup manual dulu** supaya paham tiap bagian perintahnya:

```bash
tar czf /root/coba.tar.gz -C / etc/nginx srv/site
tar tzf /root/coba.tar.gz | head
```

`-C /` membuat path di dalam arsip relatif (`etc/nginx/...`), tanpa warning dan
siap di-restore ke lokasi aslinya.

**Langkah 2. Jadikan script.**

File: `/usr/local/bin/backup-web.sh`

```bash
#!/bin/bash
# Arsipkan /etc/nginx dan /srv/site, simpan 7 hari.
set -euo pipefail

DEST=/var/backups/web
DAYS=7

mkdir -p "$DEST"
tar czf "$DEST/web-$(date +%F_%H%M).tar.gz" -C / etc/nginx srv/site
find "$DEST" -maxdepth 1 -name 'web-*.tar.gz' -mtime +"$DAYS" -delete

echo "$(date -Is) OK"
```

```bash
chmod 750 /usr/local/bin/backup-web.sh
/usr/local/bin/backup-web.sh
```

Verifikasi:

```bash
ls -la /var/backups/web
tar tzf /var/backups/web/web-*.tar.gz | head

# retensi: buat file tua, uji dengan -print dulu sebelum -delete
touch -d '10 days ago' /var/backups/web/web-lama.tar.gz
find /var/backups/web -maxdepth 1 -name 'web-*.tar.gz' -mtime +7 -print
/usr/local/bin/backup-web.sh
ls /var/backups/web                    # web-lama.tar.gz sudah hilang
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `tar: Removing leading '/'` | path absolut tanpa `-C /` | pakai `tar czf arsip -C / etc/nginx` |
| `tar: ...: Cannot stat` | path salah atau belum dibuat | cek `ls -d /etc/nginx /srv/site` |
| Script lanjut padahal tar gagal | `set -e` tidak ada | pakai `set -euo pipefail` |
| Arsip hilang sendiri | `-mtime` atau `-maxdepth` salah | uji dengan `-print` sebelum `-delete` |
| `Permission denied` saat menjalankan | script belum executable | `chmod 750 /usr/local/bin/backup-web.sh` |

Jebakan:
- Backup ke disk yang sama dengan data bukan backup. Salin juga ke tempat lain.
  Dari **[PC Windows]** cukup tarik satu arsip dengan `scp`:
  `scp -i $env:USERPROFILE\.ssh\lab <user>@<IP-VM>:/var/backups/web/web-NAMA.tar.gz .`
- Cek ruang sebelum menulis. Disk penuh di tengah backup menggagalkan arsip dan
  memperburuk keadaan (`df -h /`).
- Arsip yang tidak pernah dibuka belum terbukti bisa dipakai. Bagian 4.3
  melatih restore.

---

## 4.3 Jadwal cron dan simulasi disaster recovery

Hasil: backup jalan otomatis, dan Anda pernah melakukan restore.

Paket: `cron`.

```bash
apt-get install -y cron
```

Prasyarat: root, script dari 4.2 ada di `/usr/local/bin/backup-web.sh`, dan
`/srv/site/index.html` berisi sesuatu.

```bash
systemctl is-enabled cron
systemctl is-active cron
```

Untuk latihan, jadwal dibuat tiap menit supaya hasilnya cepat terlihat.

File: `/etc/cron.d/web-backup`

```text
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
* * * * * root /usr/local/bin/backup-web.sh >> /var/log/web-backup.log 2>&1
```

```bash
chmod 644 /etc/cron.d/web-backup
```

Verifikasi jadwal terbaca dan jalan (tunggu 2 menit):

```bash
journalctl -u cron -n 20 --no-pager | grep CMD
cat /var/log/web-backup.log
ls -la /var/backups/web
```

Setelah terbukti, ubah baris jadwal di file yang sama ke tiap hari jam 02:30:

File: `/etc/cron.d/web-backup`

```text
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
30 2 * * * root /usr/local/bin/backup-web.sh >> /var/log/web-backup.log 2>&1
```

Simulasi disaster recovery:

```bash
# 1. catat kondisi awal
sha256sum /srv/site/index.html

# 2. hapus data
rm /srv/site/index.html

# 3. restore dari arsip terbaru, hanya satu file
LATEST=$(ls -t /var/backups/web/web-*.tar.gz | head -1)
tar xzf "$LATEST" -C / srv/site/index.html

# 4. bandingkan
sha256sum /srv/site/index.html
cat /srv/site/index.html
```

`sha256sum` harus sama dengan langkah 1.

Uji script dengan environment minimal, menyerupai cron:

```bash
env -i /bin/bash -c '/usr/local/bin/backup-web.sh'
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| Jalan manual, gagal di cron | `PATH` cron tidak memuat `/usr/local/bin` | tulis `PATH=` di file cron |
| `cron` abaikan file | nama file mengandung titik, atau mode 664 | rename tanpa titik, `chmod 644` |
| Tidak ada output sama sekali | cron mati | `systemctl enable --now cron` |
| Restore menimpa config yang lebih baru | ekstrak seluruh arsip | ekstrak path tertentu saja |

Jebakan:
- File di `/etc/cron.d` harus milik `root:root`, tanpa ekstensi, dan diakhiri
  newline. Baris jadwal wajib memuat nama user (`root`).
- Jadwal tiap menit membuat satu arsip per menit. Jangan dibiarkan, ganti ke
  jadwal harian setelah uji.
- `tar xzf arsip -C /` tanpa argumen path menimpa semua yang ada di arsip.
- Restore adalah satu-satunya bukti backup berguna. Backup yang belum pernah
  di-restore masih asumsi.

---

## 4.4 Alert ke Telegram

Hasil: server mengirim pesan Telegram sendiri saat ada kejadian yang perlu
perhatian. Empat alert, semuanya sederhana dan masing-masing punya cara
memicunya:

| Alert | Cara memicu | Pesan yang masuk |
|---|---|---|
| Server menyala dan mati | `reboot` atau `poweroff` | `BOOT: ...`, `SHUTDOWN: ...` |
| nginx mati | `systemctl stop nginx` | `ALERT: nginx MATI`, lalu `RECOVERY` saat hidup |
| Login SSH | login dari PC | `SSH LOGIN: <user> dari <IP-PC>` |
| Disk hampir penuh | jalankan script dengan ambang kecil | `DISK ...%` |

Paket: `curl`, `cron`, `nginx` (nginx jadi objek alert).

```bash
apt-get install -y curl cron nginx
```

Prasyarat: root, akun Telegram, sesi SSH kedua terbuka (untuk 4.4.4).

### 4.4.1 Siapkan bot dan fungsi kirim pesan

Buat bot di aplikasi Telegram:
1. Chat `@BotFather`, kirim `/newbot`, ikuti pertanyaannya, simpan **token**.
2. Cari bot Anda lewat namanya, buka, kirim `/start`. Tanpa langkah ini bot
   tidak boleh mengirim pesan ke Anda.
3. Di browser PC, buka `https://api.telegram.org/bot<token>/getUpdates`.
   Cari bagian `"chat":{"id":123456789`. Angka itu adalah **chat id**.

Simpan token dan chat id di file khusus, bukan di script.

File: `/etc/alert.env`

```text
TG_TOKEN=ISI_TOKEN_DARI_BOTFATHER
TG_CHAT=ISI_CHAT_ID
```

```bash
chmod 600 /etc/alert.env
```

Script kirim pesan.

File: `/usr/local/bin/notify.sh`

```bash
#!/bin/bash
# Kirim satu pesan ke Telegram. Isi pesan diambil dari argumen.
set -euo pipefail
. /etc/alert.env
MSG="[$(hostname)] $*"

curl -fsS -m 10 \
  --data-urlencode "chat_id=${TG_CHAT}" \
  --data-urlencode "text=${MSG}" \
  "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null

echo "sent: $MSG"
```

```bash
chmod 755 /usr/local/bin/notify.sh
/usr/local/bin/notify.sh "tes dari $(hostname)"
```

Pesan `[nama-host] tes dari nama-host` harus muncul di Telegram dalam beberapa
detik.

### 4.4.2 Alert server menyala dan mati

Satu service systemd: `ExecStart` jalan saat boot, `ExecStop` jalan saat
shutdown, selagi jaringan masih hidup.

File: `/etc/systemd/system/alert-boot.service`

```ini
[Unit]
Description=Alert Telegram saat server boot dan shutdown
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/notify.sh "BOOT: server menyala"
ExecStop=/usr/local/bin/notify.sh "SHUTDOWN: server dimatikan"
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now alert-boot
```

`enable --now` langsung menjalankan `ExecStart`, jadi pesan `BOOT` masuk
sekarang. Itu uji pertama.

Cara memicu alert:

```bash
reboot
```

Dalam sekitar satu menit, Telegram menerima `SHUTDOWN` dan setelah VM hidup
kembali, `BOOT`. Login ulang, lalu periksa:

```bash
systemctl status alert-boot --no-pager
```

### 4.4.3 Alert nginx mati

Script cek dijalankan cron tiap menit. Pesan hanya dikirim saat status
berubah, jadi tidak membanjiri chat.

File: `/usr/local/bin/check-nginx.sh`

```bash
#!/bin/bash
# Alert sekali saat nginx mati, dan sekali saat hidup lagi.
STATE=/run/nginx-alert.state

if systemctl is-active --quiet nginx; then
  if [ -f "$STATE" ]; then
    rm -f "$STATE"
    /usr/local/bin/notify.sh "RECOVERY: nginx aktif lagi" || echo "alert gagal"
  fi
else
  if [ ! -f "$STATE" ]; then
    touch "$STATE"
    /usr/local/bin/notify.sh "ALERT: nginx MATI" || echo "alert gagal"
  fi
fi
exit 0
```

Pemeriksa disk, metrik tambahan yang paling mudah.

File: `/usr/local/bin/check-disk.sh`

```bash
#!/bin/bash
# Alert kalau pemakaian disk / melewati ambang (default 80%).
THRESHOLD=${THRESHOLD:-80}
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')

if [ "$USED" -ge "$THRESHOLD" ]; then
  /usr/local/bin/notify.sh "DISK ${USED}% (ambang ${THRESHOLD}%)" || echo "alert gagal"
fi
exit 0
```

Jadwal cron untuk keduanya.

File: `/etc/cron.d/alert-check`

```text
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
* * * * * root /usr/local/bin/check-nginx.sh
*/15 * * * * root /usr/local/bin/check-disk.sh
```

```bash
chmod 755 /usr/local/bin/check-nginx.sh /usr/local/bin/check-disk.sh
chmod 644 /etc/cron.d/alert-check
systemctl is-active cron
```

Cara memicu alert nginx:

```bash
systemctl stop nginx          # tunggu sampai 1 menit: pesan ALERT: nginx MATI
systemctl start nginx         # tunggu sampai 1 menit: pesan RECOVERY
```

Simulasi nginx crash, bukan stop biasa:

```bash
pkill -9 nginx                # tunggu: ALERT lagi
systemctl start nginx         # tunggu: RECOVERY
```

Cara memicu alert disk:

```bash
THRESHOLD=1 /usr/local/bin/check-disk.sh    # harus mengirim DISK ...%
THRESHOLD=99 /usr/local/bin/check-disk.sh   # harus senyap
```

### 4.4.4 Alert login SSH

PAM memanggil script setiap sesi SSH terbuka. Script hanya mengirim pesan, tidak
pernah menahan login.

File: `/usr/local/bin/ssh-login-alert.sh`

```bash
#!/bin/bash
# Dipanggil pam_exec. PAM_TYPE, PAM_USER, PAM_RHOST diisi oleh PAM.
[ "${PAM_TYPE:-}" = "open_session" ] || exit 0
( /usr/local/bin/notify.sh "SSH LOGIN: ${PAM_USER} dari ${PAM_RHOST}" >/dev/null 2>&1 & )
exit 0
```

```bash
chmod 755 /usr/local/bin/ssh-login-alert.sh
```

Tambahkan satu baris di bagian paling bawah file PAM untuk sshd. Biarkan sesi
SSH kedua terbuka sampai uji selesai.

File: `/etc/pam.d/sshd` (tambahkan di baris paling bawah)

```text
session optional pam_exec.so /usr/local/bin/ssh-login-alert.sh
```

Cara memicu alert, dari **[PC Windows]**:

```powershell
ssh -i $env:USERPROFILE\.ssh\lab <user>@<IP-VM>
```

Dalam beberapa detik, Telegram menerima `SSH LOGIN: <user> dari <IP-PC>`.
Keluar dengan `exit`, lalu coba lagi memakai `scp` atau `ssh` dari jendela
lain: tiap sesi baru menghasilkan satu pesan.

Rollback kalau login bermasalah, dari sesi kedua atau console: hapus baris
`pam_exec` tadi dari `/etc/pam.d/sshd`.

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `curl: (22) ... 401` | token salah atau kedaluwarsa | buat token baru di `@BotFather`, perbarui `/etc/alert.env` |
| `curl: (22) ... 400` | `chat_id` salah, atau bot belum pernah di-`/start` | kirim `/start` ke bot, ambil ulang id dari `getUpdates` |
| `getUpdates` hasilnya kosong | belum ada pesan ke bot | kirim `/start`, muat ulang halaman |
| `notify.sh: ... alert.env: No such file` | `/etc/alert.env` belum dibuat | buat file, `chmod 600` |
| Pesan terkirim tapi tidak ada alert nginx | cron mati, atau script belum executable | `systemctl is-active cron`, `chmod 755` script |
| Pesan `BOOT` tidak datang setelah reboot | jaringan belum siap saat `ExecStart` | `journalctl -u alert-boot -b`, cek `systemctl status alert-boot` |
| Pesan `SHUTDOWN` tidak datang | VM dimatikan paksa | pakai `poweroff` atau Shutdown dari Proxmox, bukan Stop |
| Tidak ada pesan login SSH | script tidak executable, atau baris PAM salah | `chmod 755`, cek baris di `/etc/pam.d/sshd` |
| Alert tidak jalan dari cron | `/etc/alert.env` tidak terbaca, atau path script salah | `ls -l /etc/alert.env`, cek `journalctl -u cron -n 20` |

Jebakan:
- Jangan menaruh token di script atau di file cron. Token masuk riwayat shell
  dan bisa terkirim ke repo. Pakai file env mode 600.
- Token terlihat di `ps aux` sepersekian detik selagi `curl` berjalan, karena
  Telegram menaruhnya di URL. Cukup untuk lab, tetapi jangan pakai token yang
  sama di tempat lain.
- Kegagalan alert tidak boleh menggagalkan pekerjaan utama. Karena itu
  script cek memakai `|| echo "alert gagal"`, dan script PAM selalu `exit 0`.
- `exit 0` di akhir script cek wajib. Cron membaca exit non-zero sebagai
  kegagalan, padahal "nginx sehat" adalah hasil normal.
- `/run/nginx-alert.state` hilang saat reboot. Kalau nginx mati sejak boot,
  alert dikirim lagi, dan itu disengaja.
- Alert SHUTDOWN hanya untuk shutdown yang rapi. Listrik padam atau Stop paksa
  tidak punya kesempatan mengirim pesan. Untuk itu perlu pemantau dari luar.
