# Modul 4: Backup, Alerting & Automation

Setiap sub-topik berdiri sendiri. Tidak ada prasyarat dari modul lain.

Total 80 menit untuk keempat sub-topik.

Konvensi:
- `<path>` direktori yang dibackup, mis. `/etc/nginx` atau `/opt/app`.
- Semua perintah sebagai `root`.
- OS acuan Debian 13.1, cron 3.0pl1, sqlite3 3.46.1.

---

## 4.1 Update keamanan otomatis · 15 menit

Hasil: patch keamanan terpasang sendiri tiap hari, tanpa `apt upgrade` manual.

Prasyarat: root, repo apt aktif.

```bash
apt-get install -y unattended-upgrades

# aktifkan jadwal. Tanpa dua baris ini paketnya terpasang tapi tidak jalan
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

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
| `--dry-run` tidak melakukan apa pun | `20auto-upgrades` tidak ada atau bernilai 0 | tulis ulang file itu, lalu `apt-config dump` |
| Upgrade tidak jalan pada jadwal | timer tidak aktif | `systemctl enable --now apt-daily.timer apt-daily-upgrade.timer` |
| Butuh reboot setelah update | kernel atau libc berubah | `Unattended-Upgrade::Automatic-Reboot "true";` dan set jamnya, atau reboot manual |
| Email laporan tidak masuk | tidak ada MTA | baca file log, atau kirim sendiri lewat script alerting (4.4) |

Jebakan:
- Debian hanya mengambil origin `label=Debian` dan `Debian-Security`. Ubuntu
  memakai pola berbeda. Jangan salin config antar distro.
- Kernel baru tidak aktif sebelum reboot. Catat kebutuhan reboot, jangan
  mengaktifkan auto-reboot di server produksi tanpa jendela maintenance.
- `--dry-run` tetap menulis log. Jangan bingung melihat entri baru.

---

## 4.2 Script backup file dan database · 25 menit

Hasil: satu script yang membuat arsip, memverifikasi integritasnya, dan
memangkas arsip lama.

Prasyarat: root. Contoh memakai `/srv/data` dan satu database SQLite; ganti ke
path dan database Anda.

```bash
# data contoh
mkdir -p /srv/data
printf 'konfigurasi penting\n' > /srv/data/app.conf

apt-get install -y sqlite3
mkdir -p /srv/data/db
sqlite3 /srv/data/db/app.db "CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, note TEXT);
INSERT INTO t(note) VALUES ('data penting');"
```

Script:

```bash
cat > /usr/local/bin/backup.sh <<'SH'
#!/bin/bash
# Backup direktori + dump sqlite, verifikasi sha256, retensi 7 hari.
set -euo pipefail

SRC=/srv/data
DB=/srv/data/db/app.db
DEST=/var/backups/app
DAYS=7
STAMP=$(date +%F_%H%M)
ARCHIVE="$DEST/app-$STAMP.tar.gz"

mkdir -p "$DEST"

# .backup = dump konsisten, aman walau database sedang dipakai
sqlite3 "$DB" ".backup '$DEST/app-$STAMP.db'"

# -C / menghasilkan path relatif di dalam arsip, tanpa warning
tar czf "$ARCHIVE" -C / "${SRC#/}"

sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

find "$DEST" -maxdepth 1 -name '*.tar.gz' -mtime +"$DAYS" -delete
find "$DEST" -maxdepth 1 -name 'app-*.db' -mtime +"$DAYS" -delete

echo "$(date -Is) OK $ARCHIVE $(stat -c%s "$ARCHIVE") bytes"
SH
chmod 750 /usr/local/bin/backup.sh
/usr/local/bin/backup.sh
```

Verifikasi:

```bash
ls -la /var/backups/app
sha256sum -c /var/backups/app/*.sha256
tar tzf /var/backups/app/app-*.tar.gz

# retensi: buat file tua, uji dengan -print dulu sebelum -delete
touch -d '10 days ago' /var/backups/app/app-2020-01-01_0000.tar.gz
find /var/backups/app -maxdepth 1 -name '*.tar.gz' -mtime +7 -print
/usr/local/bin/backup.sh
ls /var/backups/app
```

Database server (DOKUMENTASI, tidak diuji di modul ini):

```bash
# PostgreSQL
sudo -u postgres pg_dump -Fc "$DB_NAME" > "$DEST/$DB_NAME-$STAMP.dump"
sudo -u postgres pg_restore -d "$DB_NAME" --clean --if-exists "$DEST/$DB_NAME-$STAMP.dump"

# MySQL / MariaDB
mysqldump --single-transaction --routines --triggers "$DB_NAME" | gzip > "$DEST/$DB_NAME-$STAMP.sql.gz"
zcat "$DEST/$DB_NAME-$STAMP.sql.gz" | mysql "$DB_NAME"
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `tar: Removing leading '/'` | path absolut tanpa `-C /` | pakai `tar czf arsip -C / etc/nginx` |
| `sha256sum -c` FAILED | arsip terpotong, biasanya disk penuh | buang arsip, cek `df -h`, ulangi |
| Script lanjut padahal dump gagal | `set -e` tidak ada | pakai `set -euo pipefail` |
| Arsip hilang sendiri | `-mtime` atau `-maxdepth` salah | uji dengan `-print` sebelum `-delete` |

Jebakan:
- `cp app.db backup.db` saat database hidup menghasilkan file rusak. Pakai
  `.backup` untuk SQLite, `pg_dump`/`mysqldump` untuk server.
- Backup ke disk yang sama dengan data bukan backup. Kirim ke host lain
  (`rsync -az`) atau object storage.
- Cek ruang sebelum menulis. Disk penuh di tengah backup menggagalkan arsip dan
  memperburuk keadaan.

---

## 4.3 Jadwal cron dan simulasi disaster recovery · 20 menit

Hasil: backup jalan otomatis, dan Anda pernah melakukan restore.

Prasyarat: root, script dari 4.2 atau script Anda sendiri di
`/usr/local/bin/backup.sh`, `cron` aktif (`apt-get install -y cron` bila belum).

```bash
systemctl is-enabled cron
systemctl is-active cron

cat > /etc/cron.d/app-backup <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
30 2 * * * root /usr/local/bin/backup.sh >> /var/log/app-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/app-backup
```

Verifikasi jadwal terbaca:

```bash
journalctl -u cron -n 20 --no-pager | grep CMD
```

Simulasi disaster recovery:

```bash
# 1. catat kondisi awal
sha256sum /srv/data/app.conf

# 2. rusak data
echo 'rusak' > /srv/data/app.conf

# 3. restore dari arsip terbaru
LATEST=$(ls -t /var/backups/app/app-*.tar.gz | head -1)
tar xzf "$LATEST" -C / srv/data/app.conf

# 4. bandingkan
sha256sum /srv/data/app.conf
```

`sha256sum` harus sama dengan langkah 1.

Uji script dengan environment minimal, menyerupai cron:

```bash
env -i /bin/bash -c '/usr/local/bin/backup.sh'
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
  newline.
- `tar xzf arsip -C /` tanpa argumen path menimpa semua yang ada di arsip.
- Restore adalah satu-satunya bukti backup berguna. Backup yang belum pernah
  di-restore masih asumsi.

---

## 4.4 Notifikasi ke Telegram atau Discord · 20 menit

Hasil: server mengirim pesan sendiri saat ada kondisi yang perlu perhatian.

Prasyarat: root, `curl` dan `jq`, bot Telegram atau webhook Discord.

Buat bot: chat `@BotFather`, `/newbot`, simpan token. Ambil chat id dengan
mengirim pesan ke bot lalu membuka
`https://api.telegram.org/bot<token>/getUpdates`. Webhook Discord: Server
Settings, Integrations, Webhooks, New Webhook, Copy URL.

```bash
apt-get install -y curl jq

cat > /etc/alert.env <<'ENV'
PROVIDER=${PROVIDER:-telegram}
TG_TOKEN=${TG_TOKEN:-ISI_TOKEN}
TG_CHAT=${TG_CHAT:-ISI_CHAT_ID}
TG_API=${TG_API:-https://api.telegram.org}
DISCORD_WEBHOOK=${DISCORD_WEBHOOK:-}
ENV
chmod 600 /etc/alert.env

cat > /usr/local/bin/notify.sh <<'SH'
#!/bin/bash
# Kirim satu baris alert. Pesan diambil dari argumen.
set -euo pipefail
set -a; . /etc/alert.env; set +a
MSG="[$(hostname)] $*"

case "${PROVIDER}" in
  telegram)
    curl -fsS -m 10 \
      --data-urlencode "chat_id=${TG_CHAT}" \
      --data-urlencode "text=${MSG}" \
      "${TG_API}/bot${TG_TOKEN}/sendMessage" >/dev/null ;;
  discord)
    curl -fsS -m 10 -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg m "$MSG" '{content:$m}')" \
      "${DISCORD_WEBHOOK}" >/dev/null ;;
  *) echo "PROVIDER tidak dikenal" >&2; exit 1 ;;
esac
echo "sent: $MSG"
SH
chmod 755 /usr/local/bin/notify.sh

/usr/local/bin/notify.sh "tes dari $(hostname)"
```

Verifikasi tanpa token asli, dengan penampung lokal:

```bash
cat > /tmp/capture.py <<'PY'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n).decode()
        open('/tmp/captured.txt', 'w').write(
            "PATH=%s\nCT=%s\nBODY=%s\n" % (self.path, self.headers.get('Content-Type'), body))
        self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 9099), H).handle_request()
PY
setsid python3 /tmp/capture.py >/dev/null 2>&1 < /dev/null &
sleep 1
TG_API=http://127.0.0.1:9099 /usr/local/bin/notify.sh "pesan uji"
sleep 1; cat /tmp/captured.txt
```

Keluaran yang benar: `PATH=/bot<token>/sendMessage` dan body
`chat_id=...&text=...` dalam bentuk urlencoded.

Pemeriksa disk berkala:

```bash
cat > /usr/local/bin/check-disk.sh <<'SH'
#!/bin/bash
set -euo pipefail
THRESHOLD=${THRESHOLD:-80}
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$USED" -ge "$THRESHOLD" ]; then
  /usr/local/bin/notify.sh "DISK ${USED}% (ambang ${THRESHOLD}%)"
fi
exit 0
SH
chmod 755 /usr/local/bin/check-disk.sh

cat > /etc/cron.d/diskcheck <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
*/15 * * * * root /usr/local/bin/check-disk.sh
CRON
chmod 644 /etc/cron.d/diskcheck

THRESHOLD=1 /usr/local/bin/check-disk.sh    # harus mengirim
THRESHOLD=99 /usr/local/bin/check-disk.sh   # harus senyap
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `curl: (22) ... 401` | token salah atau kedaluwarsa | buat token baru di `@BotFather` |
| `curl: (22) ... 400` | `chat_id` salah, atau bot belum pernah di-`/start` | kirim `/start` ke bot, ambil ulang id |
| Pesan terkirim tapi salah format | teks tidak di-urlencode | pakai `--data-urlencode` |
| Alert tidak jalan dari cron | `/etc/alert.env` tidak terbaca, atau `jq` tidak ada | `ls -l /etc/alert.env`, `apt-get install -y jq` |

Jebakan:
- Jangan menaruh token di argumen `curl` atau di cron. Token terlihat di
  `ps aux` dan tersimpan di riwayat shell. Pakai file env mode 600.
- Kegagalan alert tidak boleh menggagalkan backup. Tambahkan `|| echo "alert
  gagal" >> log` setelah pemanggilan.
- `exit 0` di akhir `check-disk.sh` wajib. Cron membaca exit non-zero sebagai
  kegagalan, padahal "disk masih aman" adalah hasil normal.
