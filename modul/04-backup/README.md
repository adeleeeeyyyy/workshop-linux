# Topik 4 — Backup, Alerting & Automation

Estimasi waktu: **80 menit** (4 sub-topik).

Lingkungan uji fact-check: Debian GNU/Linux 13.1 (trixie), 1 vCPU, 1 GB RAM,
unattended-upgrades 2.12, cron 3.0pl1-197, sqlite3 3.46.1, curl 8.14.1, jq 1.7.1.
Semua perintah dijalankan di mesin uji pada 14 November 2026 kecuali yang
ditandai DOKUMENTASI.

## Prasyarat / kondisi awal VM

- Topik 1–3 selesai: `hello.service` jalan, nginx melayani
  `https://hello.lab.test`, UFW + fail2ban aktif.
- Disk masih lega: `df -h /` → `Use%` < 50%.

---

## 4.1 Automasi security update (unattended-upgrades) — 15 menit

Tujuan: patch keamanan masuk otomatis tanpa peserta harus ingat `apt upgrade`.

### Langkah 1 — Install dan lihat konfigurasi bawaan

```bash
apt-get install -y unattended-upgrades
dpkg -l unattended-upgrades | tail -1
cat /etc/apt/apt.conf.d/20auto-upgrades
```

Output yang diharapkan:

```
ii  unattended-upgrades 2.12   all   automatic installation of security upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

Kenapa `20auto-upgrades` adalah kunci: tanpa dua baris ini, paketnya terpasang
tapi **tidak pernah menjalankan apa pun**. `apt-config dump` membuktikan
nilainya terbaca:

```bash
apt-config dump APT::Periodic::Update-Package-Lists APT::Periodic::Unattended-Upgrade
```

### Langkah 2 — Cek origin paket yang diizinkan

```bash
grep -vE '^\s*(//|$)' /etc/apt/apt.conf.d/50unattended-upgrades | head -12
```

Output yang diharapkan:

```
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Package-Blacklist {
};
```

Kenapa ini penting: di Debian, pola default hanya mengambil **security** dan
`stable` (bukan backports/experimental). Di Ubuntu, pola default mencakup
`${distro_id}:${distro_codename}-security` — jangan menyalin konfigurasi Debian
ke Ubuntu atau sebaliknya tanpa cek.

Lokasi log:

```bash
ls -l /var/log/unattended-upgrades/ 2>&1
```

### Langkah 3 — Verifikasi jadwal dan uji kering

```bash
systemctl list-timers 'apt*' --no-pager | head -5
systemctl is-enabled unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
unattended-upgrade --dry-run
```

Output yang diharapkan:

```
NEXT                        LEFT LAST PASSED UNIT
Sun 2026-11-15 02:10:41 UTC  17h  -    -    apt-daily.timer
Sun 2026-11-15 06:01:18 UTC  21h  -    -    apt-daily-upgrade.timer
enabled
enabled
enabled
```

`--dry-run` mencetak perintah `dpkg` yang **akan** dijalankan tanpa
menjalankannya. Pada uji ini terlihat paket `zlib1g` akan di-upgrade — artinya
konfigurasi bekerja dan memang ada update tertunda.

Kenapa `--dry-run` dan bukan langsung `unattended-upgrade -d`: menjalankan
upgrade sungguhan di tengah workshop akan menambah risiko (service restart
mendadak, kernel baru). Cukup buktikan jadwal dan paket target.

### Langkah 4 — Log hasil upgrade

`unattended-upgrades` menulis sendiri ke `/var/log/unattended-upgrades/`:

```bash
ls -l /var/log/unattended-upgrades/
tail -5 /var/log/unattended-upgrades/unattended-upgrades.log
```

Output yang diharapkan (nyata dari uji `--dry-run`):

```
-rw-r--r-- 1 root adm  2747 Nov 14 08:39 unattended-upgrades-dpkg.log
-rw-r--r-- 1 root root 2061 Nov 14 08:39 unattended-upgrades.log
2026-11-14 08:37:44,927 INFO Option --dry-run given, *not* performing real actions
2026-11-14 08:37:44,928 INFO Packages that will be upgraded: apt apt-utils base-files bash ...
2026-11-14 08:39:14,928 INFO All upgrades installed
```

Baris `Packages that will be upgraded:` adalah daftar yang paling berguna saat
audit: di mesin uji isinya 93 paket termasuk `openssh-server`, `systemd`, dan
`openssl`. Tanpa `--dry-run`, di sinilah peserta melihat apa yang berubah
semalam.

Soal email: `Unattended-Upgrade::Mail` hanya berguna kalau ada MTA. Mesin uji
**sudah** punya `postfix 3.10.4` aktif (`systemctl is-active postfix` →
`active`), jadi email akan masuk ke mailbox lokal `root`, bukan ke luar. Pada
image minimal tanpa MTA, email di atas tidak terkirim dan tidak ada error yang
terlihat — karena itu modul ini memakai file log, bukan email, sebagai bukti.

---

## 4.2 Bash script untuk backup file & database — 25 menit

Tujuan: satu script yang bisa dijalankan manual maupun oleh cron, menghasilkan
arsip yang bisa diverifikasi, dengan retensi otomatis.

### Langkah 1 — Siapkan data yang akan dibackup

```bash
apt-get install -y sqlite3
mkdir -p /opt/hello/db
sqlite3 /opt/hello/db/app.db "CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, note TEXT);
INSERT INTO t(note) VALUES ('data penting');"
sqlite3 /opt/hello/db/app.db "SELECT count(*) FROM t;"
```

Output: `1`.

Kenapa SQLite dipakai di lab: tidak butuh server database, tapi
**pola backup-nya sama** dengan PostgreSQL/MySQL — untuk database file-based
wajib pakai mekanisme konsisten (`.backup`), bukan `cp` saat file sedang
ditulis. Contoh untuk server database ada di akhir sub-topik ini.

### Langkah 2 — Script backup

```bash
cat > /usr/local/bin/hello-backup.sh <<'SH'
#!/bin/bash
# Backup /etc/hello, /opt/hello, config nginx + dump sqlite. Retensi 7 hari.
set -euo pipefail

BACKUP_DIR=/var/backups/hello
RETENTION_DAYS=7
STAMP=$(date +%F_%H%M)
ARCHIVE="$BACKUP_DIR/hello-$STAMP.tar.gz"

mkdir -p "$BACKUP_DIR"

# dump database secara konsisten (bukan cp file .db)
sqlite3 /opt/hello/db/app.db ".backup '$BACKUP_DIR/app-$STAMP.db'"

# -C / supaya path di dalam arsip relatif dan tidak muncul warning
tar czf "$ARCHIVE" -C / \
    etc/hello \
    opt/hello \
    etc/nginx/sites-available/hello.conf

sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

# retensi
find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz'  -mtime +"$RETENTION_DAYS" -delete
find "$BACKUP_DIR" -maxdepth 1 -name 'app-*.db'  -mtime +"$RETENTION_DAYS" -delete
find "$BACKUP_DIR" -maxdepth 1 -name '*.sha256'  -mtime +"$RETENTION_DAYS" -delete

echo "$(date -Is) OK $ARCHIVE $(stat -c%s "$ARCHIVE") bytes"
SH
chmod 750 /usr/local/bin/hello-backup.sh
/usr/local/bin/hello-backup.sh
```

Output yang diharapkan:

```
2026-11-14T09:10:08+00:00 OK /var/backups/hello/hello-2026-11-14_0910.tar.gz 1399 bytes
```

Baris yang perlu dijelaskan ke peserta:
- `set -euo pipefail` — berhenti di error pertama, gagal pada variabel kosong,
  dan gagal kalau salah satu bagian pipeline error. Tanpa ini, script bisa
  "sukses" padahal arsipnya kosong.
- `-C /` pada `tar` — path di dalam arsip jadi relatif (`etc/hello/...`).
  Tanpa ini, `tar` memotong `/` di depan nama file dan menulis warning ke
  stderr yang sering diabaikan.
- `.backup` pada sqlite3 — dump konsisten, aman walau database sedang dipakai.
- `sha256sum` — bukti integritas; bisa dicek kapan saja tanpa membuka arsip.

### Langkah 3 — Verifikasi arsip benar-benar bisa dipakai

```bash
ls -la /var/backups/hello
sha256sum -c /var/backups/hello/*.tar.gz.sha256
tar tzf /var/backups/hello/hello-*.tar.gz | head -6
```

Output yang diharapkan:

```
/var/backups/hello/hello-2026-11-14_0910.tar.gz: OK
etc/hello/
etc/hello/hello.env
opt/hello/
opt/hello/app.py
opt/hello/db/
opt/hello/db/app.db
etc/nginx/sites-available/hello.conf
```

Kenapa `sha256sum -c` bukan sekadar `ls`: arsip yang ada belum tentu arsip yang
utuh. Cek ini murah dan bisa dijalankan otomatis.

### Langkah 3b — Buktikan retensi bekerja

Retensi adalah bagian yang paling sering salah dan paling berbahaya (bisa
menghapus arsip yang masih dibutuhkan). Uji dengan file berumur 10 hari:

```bash
touch -d '10 days ago' /var/backups/hello/hello-2020-01-01_0000.tar.gz
touch -d '10 days ago' /var/backups/hello/app-2020-01-01_0000.db
find /var/backups/hello -maxdepth 1 -name '*.tar.gz' -mtime +7 -print
```

Output yang diharapkan: **hanya** file lama yang terdaftar —

```
/var/backups/hello/hello-2020-01-01_0000.tar.gz
```

Baru setelah itu jalankan backup lagi, dan pastikan file lama hilang sedangkan
arsip baru tetap ada:

```bash
/usr/local/bin/hello-backup.sh
ls /var/backups/hello/
```

Selalu uji dengan `-print` dulu, baru `-delete`. Satu typo di `-maxdepth` atau
pola `-name` bisa menghapus arsip yang masih berlaku.

### Langkah 4 — Pola untuk database server (DOKUMENTASI)

Untuk PostgreSQL:

```bash
sudo -u postgres pg_dump -Fc "$DB_NAME" > "$BACKUP_DIR/${DB_NAME}-$STAMP.dump"
# restore: pg_restore -d "$DB_NAME" --clean --if-exists file.dump
```

Untuk MySQL/MariaDB:

```bash
mysqldump --single-transaction --routines --triggers "$DB_NAME" | gzip > "$BACKUP_DIR/${DB_NAME}-$STAMP.sql.gz"
# restore: zcat file.sql.gz | mysql "$DB_NAME"
```

Dua flag itu bukan kosmetik: `-Fc` menghasilkan format custom yang bisa
di-restore selektif, dan `--single-transaction` (InnoDB) memberi snapshot
konsisten tanpa mengunci tabel. Tidak dijalankan di mesin uji karena tidak ada
server database di lab ini — status DOKUMENTASI.

---

## 4.3 Penjadwalan cron & simulasi disaster recovery — 20 menit

Tujuan: backup jalan sendiri setiap hari, dan **peserta pernah melakukan
restore** — bukan hanya membuat backup.

### Langkah 1 — Pastikan cron hidup

```bash
dpkg -l cron | tail -1
systemctl is-enabled cron
systemctl is-active cron
```

Output yang diharapkan:

```
ii  cron  3.0pl1-197  amd64  process scheduling daemon
enabled
active
```

Pada image Debian 13 yang dipakai, `cron` sudah terpasang dan aktif. Kalau
tidak: `apt-get install -y cron`.

Kenapa bukan `systemd timer`: keduanya sah. `cron.d` lebih mudah dipahami
peserta dan lebih portabel; `systemd timer` lebih baik untuk dependency dan
logging terstruktur. Modul ini memakai cron sesuai outline.

### Langkah 2 — Jadwal di `/etc/cron.d`

```bash
cat > /etc/cron.d/hello-backup <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
30 2 * * * root /usr/local/bin/hello-backup.sh >> /var/log/hello-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/hello-backup
cat /etc/cron.d/hello-backup
```

Kenapa `PATH` ditulis eksplisit: cron tidak mewarisi environment shell
interaktif. Tanpa `PATH`, `sqlite3` atau `tar` bisa "command not found" padahal
manual jalan — penyebab nomor satu cron yang "tidak jalan".

Kenapa `MAILTO=""`: tanpa MTA, cron mencoba mengirim mail dan menulis error ke
log sistem setiap hari. Kosongkan supaya output hanya ke file.

Kenapa `chmod 644`: cron menolak file di `cron.d` yang writable oleh group/other.

Tiga jebakan lain yang harus disebut:
- File **tidak boleh** punya ekstensi (bukan `hello-backup.sh`) dan tidak boleh
  ada titik di nama file — `run-parts` melewatinya.
- Harus ada newline di akhir file.
- File milik `root:root`.

### Langkah 3 — Simulasi disaster recovery (bagian inti)

```bash
# 1. buktikan service jalan
curl -s http://127.0.0.1:8080/ ; echo

# 2. hancurkan: pindahkan file aplikasi
mv /opt/hello/app.py /root/app.py.hilang
systemctl restart hello
sleep 2
systemctl is-active hello
systemctl status hello --no-pager | sed -n '4,8p'
```

Output yang diharapkan: `activating` (bukan `active`), dan detail:

```
Process: 11279 ExecStart=/usr/bin/python3 /opt/hello/app.py (code=exited, status=2)
Main PID: 11279 (code=exited, status=2)
```

Ini kondisi "server mati setelah perubahan". Sekarang restore:

```bash
LATEST=$(ls -t /var/backups/hello/hello-*.tar.gz | head -1); echo "$LATEST"
tar xzf "$LATEST" -C / opt/hello/app.py
systemctl restart hello
sleep 2
systemctl is-active hello
curl -s http://127.0.0.1:8080/ ; echo
```

Output yang diharapkan: `active` lalu JSON aplikasi kembali.

Bukti bahwa isi file identik dengan sebelum insiden:

```bash
diff /root/app.py.hilang /opt/hello/app.py && echo "IDENTIK"
```

Output: `IDENTIK`.

Kenapa `ls -t | head -1` dan bukan nama file: nama arsip berisi timestamp yang
berubah setiap kali backup jalan; memilih yang terbaru adalah satu-satunya cara
yang tetap benar setelah script dipakai berhari-hari.

Kenapa restore mengekstrak **satu path** (`opt/hello/app.py`) dan bukan seluruh
arsip: `tar xzf file -C /` tanpa argumen path akan menimpa semua file termasuk
`/etc/hello/hello.env` yang mungkin sengaja diubah setelah backup. Restore
selektif = lebih kecil kemungkinan memperburuk keadaan.

### Langkah 4 — Menguji script sebagai cron (bukan sebagai shell)

Jalankan dengan environment minimal supaya ketahuan kalau ada yang bergantung
pada shell interaktif:

```bash
env -i /bin/bash -c '/usr/local/bin/hello-backup.sh'
tail -2 /var/log/hello-backup.log
```

Output yang diharapkan: satu baris `OK ... bytes` baru
(di uji: `... hello-2026-11-14_0909.tar.gz 1494 bytes`).

Kenapa `env -i`: mensimulasikan cron yang tidak punya `PATH`/`HOME` dari shell
peserta. Kalau berhasil di `env -i` tapi gagal di cron, masalahnya di
`/etc/cron.d` (PATH/SHELL/nama file), bukan di script.

### Langkah 5 — Bukti cron benar-benar mengeksekusi jadwal

Tunggu sampai jadwal terlewati, lalu lihat journal cron (di Debian 13 tanpa
rsyslog, `/var/log/syslog` tidak ada):

```bash
journalctl -u cron -n 12 --no-pager | tail -8
```

Output yang diharapkan (nyata dari uji, job `check-disk.sh` berjalan tiap 15
menit):

```
Nov 14 08:45:01 testing-debian CRON[11489]: (root) CMD (/usr/local/bin/check-disk.sh)
Nov 14 08:45:01 testing-debian CRON[11487]: pam_unix(cron:session): session closed for user root
Nov 14 09:00:01 testing-debian CRON[11906]: (root) CMD (/usr/local/bin/check-disk.sh)
```

Baris `(root) CMD (...)` adalah bukti bahwa file di `/etc/cron.d` sudah dibaca
dan dijadwalkan. Kalau baris ini tidak muncul sama sekali, masalahnya di file
cron (nama mengandung titik, permission, atau cron mati) — bukan di script.

---

## 4.4 Notifikasi alerting ke Telegram / Discord — 20 menit

Tujuan: server mengirim pesan sendiri saat ada kondisi yang perlu perhatian
(disk hampir penuh, backup selesai/gagal).

### Langkah 1 — File environment dengan permission ketat

```bash
cat > /etc/alert.env <<'ENV'
# chmod 600, jangan pernah masuk git
PROVIDER=${PROVIDER:-telegram}
TG_TOKEN=${TG_TOKEN:-ISI_TOKEN_BOT_ANDA}
TG_CHAT=${TG_CHAT:-ISI_CHAT_ID_ANDA}
TG_API=${TG_API:-https://api.telegram.org}
DISCORD_WEBHOOK=${DISCORD_WEBHOOK:-}
ENV
chmod 600 /etc/alert.env
ls -l /etc/alert.env
```

Output: `-rw------- 1 root root 238 /etc/alert.env`.

Kenapa `${VAR:-default}` dan bukan nilai langsung: memungkinkan override saat
pengujian (`TG_API=http://127.0.0.1:9099 ./notify.sh ...`) tanpa mengedit file
rahasia. Ini juga yang membuat modul ini bisa di-fact-check tanpa token asli.

Cara mendapat token: chat `@BotFather` di Telegram → `/newbot` → token
`123456:ABC...`. Chat ID: kirim pesan ke bot, lalu buka
`https://api.telegram.org/bot<TOKEN>/getUpdates` dan lihat `"chat":{"id":...}`.
Untuk Discord: Server Settings → Integrations → Webhooks → New Webhook → Copy
Webhook URL.

### Langkah 2 — Script pengirim

```bash
cat > /usr/local/bin/notify.sh <<'SH'
#!/bin/bash
# Kirim 1 baris alert. Pesan = argumen.
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
apt-get install -y curl jq
```

Kenapa `--data-urlencode`: pesan berisi spasi, `:` dan `%` — tanpa encoding,
Telegram membalas 400 `Bad Request: can't parse entities`. Ini yang membuat
`curl` mentah dari tutorial sering gagal untuk pesan dinamis.

Kenapa `>/dev/null` pada curl tapi `echo` tetap ada: body respons Telegram tidak
berguna di log; yang berguna adalah konfirmasi bahwa script berjalan.

### Langkah 3 — Cek disk berkala

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
cat > /etc/cron.d/hello-diskcheck <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
*/15 * * * * root /usr/local/bin/check-disk.sh
CRON
chmod 644 /etc/cron.d/hello-diskcheck
```

Kenapa `exit 0` di akhir: cron menganggap exit non-zero sebagai kegagalan.
Script ini "berhasil" baik saat alert terkirim maupun saat disk masih aman.

Kenapa `df --output=pcent` + `tr -dc '0-9'`: mengambil angka saja, mengabaikan
tanda `%` dan spasi. Lebih tahan terhadap perbedaan locale daripada `awk` dengan
pemisah tertentu.

### Langkah 4 — Uji tanpa token asli (bukti payload)

Cara paling cepat membuktikan konfigurasi benar sebelum menghubungkan bot nyata:
arahkan `TG_API` ke penampung lokal.

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
TG_API=http://127.0.0.1:9099 /usr/local/bin/notify.sh "backup selesai: hello.tar.gz 1.4 KB"
sleep 1; cat /tmp/captured.txt
```

Output yang diharapkan (nyata dari uji):

```
sent: [testing-debian] backup selesai: hello.tar.gz 1.4 KB
PATH=/bot000000:FAKE_TOKEN_UNTUK_UJI_LOKAL/sendMessage
CT=application/x-www-form-urlencoded
BODY=chat_id=123456789&text=%5Btesting-debian%5D+backup+selesai%3A+hello.tar.gz+1.4+KB
```

Yang dibuktikan output ini: path endpoint benar (`/bot<token>/sendMessage`),
`chat_id` dan `text` terkirim sebagai form-urlencoded, dan prefix `[hostname]`
menempel. Dengan token asli, request yang sama akan dibalas `"ok":true`.

Uji juga jalur "tidak ada alert saat aman":

```bash
THRESHOLD=99 /usr/local/bin/check-disk.sh; echo "rc=$?"
df --output=pcent / | tail -1
```

Output: tidak ada apa pun, `rc=0`, dan pemakaian disk `14%` — memang di bawah
99%.

Dan jalur "alert menyala":

```bash
THRESHOLD=1 TG_API=http://127.0.0.1:9099 /usr/local/bin/notify.sh "uji ambang"
```

### Langkah 5 — Alert dari script backup

Tambahkan satu blok di akhir `hello-backup.sh`:

```bash
MSG="$(date -Is) OK $ARCHIVE $(stat -c%s "$ARCHIVE") bytes"
echo "$MSG"
/usr/local/bin/notify.sh "backup OK: $(basename "$ARCHIVE")" \
  || echo "alert gagal" >> /var/log/hello-backup.log
```

Kenapa `|| echo ...`: kegagalan alert **tidak boleh** menggagalkan backup.
Backup adalah tujuan utama; notifikasi adalah pelengkap. Tanpa `||`, `set -e`
akan menghentikan script sebelum retensi berjalan.

Verifikasi:

```bash
setsid python3 /tmp/capture.py >/dev/null 2>&1 < /dev/null &
sleep 1
TG_API=http://127.0.0.1:9099 /usr/local/bin/hello-backup.sh
sleep 1; cat /tmp/captured.txt
```

Output yang diharapkan:

```
2026-11-14T08:47:25+00:00 OK /var/backups/hello/hello-2026-11-14_0847.tar.gz 1488 bytes
sent: [testing-debian] backup OK: hello-2026-11-14_0847.tar.gz
BODY=chat_id=123456789&text=%5Btesting-debian%5D+backup+OK%3A+hello-2026-11-14_0847.tar.gz
```

### 4.5 Realitas pengiriman ke Telegram/Discord

```bash
TG_TOKEN=000000:FAKE /usr/local/bin/notify.sh "tes"
```

Output: `curl: (22) The requested URL returned error: 401`.

Artinya: request **berhasil keluar** ke `api.telegram.org` dan endpoint menolak
token. Ini bukti jalur jaringan + format request benar, dan sekaligus pengingat
bahwa token salah tidak akan pernah "diam-diam sukses".

---

## Titik rawan

### 1. Menguji backup tanpa pernah restore

Backup yang tidak pernah di-restore adalah asumsi, bukan backup. Modul ini
memaksa restore di 4.3.3. Kalau waktu habis, prioritaskan restore dan lewati
4.4.

### 2. `find ... -delete` menghapus lebih banyak dari yang dimaksud

`find "$BACKUP_DIR" -name '*.tar.gz' -mtime +7 -delete` aman **karena**
`-maxdepth 1` dan path spesifik. Tanpa `-maxdepth`, `find` turun ke
sub-direktori dan bisa menghapus arsip di lokasi lain. Uji dulu tanpa `-delete`:

```bash
find /var/backups/hello -maxdepth 1 -name '*.tar.gz' -mtime +7 -print
```

### 3. Secret bocor lewat `ps` atau git

`notify.sh` membaca token dari `/etc/alert.env` (mode 600), bukan dari argumen
command line. Kalau peserta menulis `curl https://api.telegram.org/bot123:ABC/...`
langsung di cron, token itu terlihat di `ps aux` dan tersimpan di riwayat shell.

### 4. Backup berjalan saat disk hampir penuh

Menulis arsip ke disk yang sama yang sedang hampir penuh bisa menggagalkan
backup **dan** memperparah keadaan. Cek ruang sebelum menulis:

```bash
df --output=avail -m / | tail -1     # dalam MB
```

Untuk produksi, arahkan `BACKUP_DIR` ke mount/disk terpisah atau remote
(rsync/rclone/restic). Contoh minimal rsync ke host lain:

```bash
rsync -az --delete-after /var/backups/hello/ backup@10.10.10.5:/backup/hello/
```

### 5. Cron jalan tapi tidak ada hasil

Urutan diagnosa: (a) `systemctl is-active cron`; (b) `grep CRON /var/log/syslog`
— kalau `syslog` tidak ada (Debian 13 tanpa rsyslog), pakai
`journalctl -u cron -n 20`; (c) jalankan script dengan `env -i` (4.3.4);
(d) cek nama file di `cron.d` tidak mengandung titik.

### 6. Restore menimpa konfigurasi yang lebih baru

Restore seluruh arsip setelah perubahan konfigurasi sengaja akan mengembalikan
versi lama. Selalu restore path spesifik, atau ekstrak ke direktori sementara
lalu bandingkan dengan `diff` sebelum menyalin.

---

## Troubleshooting

| Gejala | Penyebab | Solusi |
|---|---|---|
| `unattended-upgrade --dry-run` tidak melakukan apa pun | `20auto-upgrades` tidak ada / bernilai 0 | `dpkg-reconfigure -plow unattended-upgrades`, cek `apt-config dump APT::Periodic` |
| Script backup jalan manual, gagal di cron | `PATH` di cron tidak memuat `/usr/local/bin` | tulis `PATH=` eksplisit di `/etc/cron.d/...` |
| `cron` tidak menjalankan file di `cron.d` | Nama file mengandung titik, atau file writable oleh group | rename tanpa titik; `chmod 644`; pastikan `root:root` |
| `sqlite3: command not found` di dalam script | Paket tidak terpasang, bukan masalah PATH | `apt-get install -y sqlite3` |
| `tar: Removing leading '/' from member names` | Path absolut tanpa `-C /` | pakai `tar czf arsip -C / etc/hello opt/hello` |
| `sha256sum -c` → FAILED | Arsip rusak / terpotong (mis. disk penuh saat menulis) | buang arsip itu, jalankan backup ulang, cek `df -h` |
| `curl: (22) ... error: 401` saat kirim Telegram | Token salah/kedaluwarsa | buat token baru di `@BotFather`, perbarui `/etc/alert.env` |
| `curl: (22) ... error: 400` Telegram | `chat_id` salah, atau bot belum pernah di-`/start` oleh user | kirim `/start` ke bot, ambil `chat.id` dari `getUpdates` |
| Alert tidak terkirim dari cron | `/etc/alert.env` tidak terbaca root, atau `jq` tidak ada untuk Discord | `ls -l /etc/alert.env` (600, root), `apt-get install -y jq` |
| `diff` setelah restore → beda | Backup diambil **sebelum** perubahan terakhir | itu perilaku benar; restore dari arsip yang tepat |

---

## FACT-CHECK

Diuji di Debian 13.1, 1 vCPU/1 GB, 14 November 2026.

| Langkah | Klaim yang dicek | Status | Bukti | Sumber |
|---|---|---|---|---|
| 4.1.1 | `unattended-upgrades 2.12` terpasang dan `20auto-upgrades` berisi dua baris `Periodic` | DIJALANKAN | `ii unattended-upgrades 2.12`; `APT::Periodic::Unattended-Upgrade "1";` | https://wiki.debian.org/UnattendedUpgrades |
| 4.1.2 | Pola origin default Debian hanya `label=Debian` dan `Debian-Security` | DIJALANKAN | `50unattended-upgrades` → 3 baris `origin=Debian,...` | https://wiki.debian.org/UnattendedUpgrades |
| 4.1.3 | Timer `apt-daily` dan `apt-daily-upgrade` aktif | DIJALANKAN | `Sun 2026-11-15 02:10:41 UTC apt-daily.timer`; semua `enabled` | https://wiki.debian.org/UnattendedUpgrades |
| 4.1.4 | `unattended-upgrade --dry-run` menampilkan paket yang akan di-upgrade tanpa menjalankannya | DIJALANKAN | Muncul `/usr/bin/dpkg ... --unpack ... zlib1g_1%3a1.3...deb`; log: `Packages that will be upgraded: apt apt-utils ... zlib1g` (93 paket) | https://manpages.debian.org/trixie/unattended-upgrades/unattended-upgrade.8.en.html |
| 4.1.5 | Log hasil upgrade tersedia di `/var/log/unattended-upgrades/` | DIJALANKAN | `unattended-upgrades.log` 2061 byte berisi `INFO All upgrades installed` | https://manpages.debian.org/trixie/unattended-upgrades/unattended-upgrade.8.en.html |
| 4.1.6 | Mesin uji punya MTA lokal (postfix), jadi klaim "tanpa MTA" tidak berlaku di sini | DIJALANKAN | `ii postfix 3.10.4-1~deb13u1`; `systemctl is-active postfix` → `active` | https://www.postfix.org/documentation.html |
| 4.2.1 | `sqlite3 .backup` menghasilkan file DB konsisten | DIJALANKAN | `app-2026-11-14_0839.db` 8192 byte di `/var/backups/hello` | https://sqlite.org/cli.html |
| 4.2.2 | Script backup menghasilkan arsip + sha256 dan berjalan dengan `set -euo pipefail` | DIJALANKAN | `OK /var/backups/hello/hello-2026-11-14_0910.tar.gz 1399 bytes` | https://manpages.debian.org/trixie/tar/tar.1.en.html |
| 4.2.3 | `tar -C /` menghasilkan path relatif tanpa warning | DIJALANKAN | `tar tzf` → `etc/hello/`, `etc/hello/hello.env`, `opt/hello/app.py`, `opt/hello/db/app.db`, `etc/nginx/sites-available/hello.conf` | https://manpages.debian.org/trixie/tar/tar.1.en.html |
| 4.2.4 | `sha256sum -c` memverifikasi arsip | DIJALANKAN | `/var/backups/hello/hello-2026-11-14_0910.tar.gz: OK` | https://manpages.debian.org/trixie/coreutils/sha256sum.1.en.html |
| 4.2.5 | Retensi `-mtime +7 -delete` menghapus hanya arsip tua | DIJALANKAN | `find -print` → hanya `hello-2020-01-01_0000.tar.gz`; setelah backup berikutnya file itu (dan `app-2020-01-01_0000.db`) hilang, arsip hari ini tetap ada | https://manpages.debian.org/trixie/findutils/find.1.en.html |
| 4.3.1 | `cron 3.0pl1-197` terpasang dan aktif di image | DIJALANKAN | `ii cron 3.0pl1-197`; `systemctl is-active cron` → `active` | https://manpages.debian.org/trixie/cron/cron.8.en.html |
| 4.3.2 | Format `/etc/cron.d` dengan `SHELL`/`PATH`/`MAILTO` + user diterima cron | DIJALANKAN | `journalctl -u cron` → `(root) CMD (/usr/local/bin/check-disk.sh)` pada 08:45:01 dan 09:00:01 | https://manpages.debian.org/trixie/cron/crontab.5.en.html |
| 4.3.3 | Menghapus `app.py` membuat service gagal, restore mengembalikannya | DIJALANKAN | `Main PID: 11279 (code=exited, status=2)` → setelah restore `active` + JSON kembali | https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html |
| 4.3.4 | File hasil restore identik byte-per-byte | DIJALANKAN | `diff /root/app2.hilang /opt/hello/app.py` → `IDENTIK` (restore dari `hello-2026-11-14_0910.tar.gz`) | https://manpages.debian.org/trixie/diffutils/diff.1.en.html |
| 4.3.5 | Script berjalan dengan environment minimal (`env -i`) | DIJALANKAN | `OK /var/backups/hello/hello-2026-11-14_0909.tar.gz 1494 bytes`, `rc=0` | https://manpages.debian.org/trixie/coreutils/env.1.en.html |
| 4.4.1 | `notify.sh` mengirim POST ke `/bot<token>/sendMessage` dengan body urlencoded | DIJALANKAN | `PATH=/bot000000:FAKE_TOKEN.../sendMessage`; `BODY=chat_id=123456789&text=%5Btesting-debian%5D...` | https://core.telegram.org/bots/api#sendmessage |
| 4.4.2 | `check-disk.sh` senyap saat pemakaian di bawah ambang | DIJALANKAN | `THRESHOLD=99` → tanpa output, `rc=0`, disk `14%` | https://manpages.debian.org/trixie/coreutils/df.1.en.html |
| 4.4.3 | `check-disk.sh` mengirim alert saat ambang terlampaui | DIJALANKAN | `THRESHOLD=1` → `sent: [testing-debian] DISK 14% (ambang 1%)` | https://manpages.debian.org/trixie/coreutils/df.1.en.html |
| 4.4.4 | Alert terpasang di script backup tanpa menggagalkan backup | DIJALANKAN | Backup sukses lalu `sent: ... backup OK: hello-2026-11-14_0847.tar.gz`; saat pengiriman gagal (`curl: (22) ... 401`) baris `alert gagal` masuk ke `/var/log/hello-backup.log` dan backup tetap selesai | https://core.telegram.org/bots/api#sendmessage |
| 4.4.5 | Pengiriman nyata ke Telegram dengan token palsu ditolak 401 | DIJALANKAN | `curl: (22) The requested URL returned error: 401` | https://core.telegram.org/bots/api |
| 4.4.6 | Format payload Discord `{content: ...}` lewat `jq -cn` | DOKUMENTASI | `jq` terpasang (`1.7.1`), webhook Discord tidak tersedia untuk diuji | https://discord.com/developers/docs/resources/webhook#execute-webhook |
| 4.2.6 | `pg_dump -Fc` / `mysqldump --single-transaction` | DOKUMENTASI | Tidak ada server PostgreSQL/MySQL di mesin uji | https://www.postgresql.org/docs/current/app-pgdump.html |
| 4.4.7 | Pengiriman nyata ke bot Telegram/Discord dengan token valid | BELUM TERVERIFIKASI | Butuh token & akun nyata; hanya sampai 401 dengan token palsu | https://core.telegram.org/bots/api |
