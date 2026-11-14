#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive

echo "=== [1] unattended-upgrades ==="
apt-get install -y unattended-upgrades 2>&1 | tail -3
dpkg -l unattended-upgrades | tail -1
echo "--- 20auto-upgrades ---"
cat /etc/apt/apt.conf.d/20auto-upgrades 2>&1
echo "--- 50unattended-upgrades (aktif) ---"
grep -vE '^\s*(//|$)' /etc/apt/apt.conf.d/50unattended-upgrades | head -12
echo "--- timers ---"
systemctl list-timers 'apt*' --no-pager | head -5
systemctl is-enabled unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>&1
echo "--- dry-run ---"
unattended-upgrade --dry-run 2>&1 | tail -6
echo "--- dpkg options ---"
apt-config dump APT::Periodic::Update-Package-Lists APT::Periodic::Unattended-Upgrade

echo "=== [2] cron tersedia? ==="
dpkg -l cron 2>/dev/null | grep -c ^ii; systemctl is-active cron 2>&1
apt-get install -y cron 2>&1 | tail -2
systemctl is-enabled cron 2>&1; systemctl is-active cron

echo "=== [3] contoh DB sqlite ==="
apt-get install -y sqlite3 2>&1 | tail -1
mkdir -p /opt/hello/db
[ -f /opt/hello/db/app.db ] || sqlite3 /opt/hello/db/app.db "CREATE TABLE t(id INTEGER PRIMARY KEY, note TEXT); INSERT INTO t(note) VALUES ('data penting');"
sqlite3 /opt/hello/db/app.db "SELECT count(*) FROM t;"

echo "=== [4] backup script ==="
cat > /usr/local/bin/hello-backup.sh <<'SH'
#!/bin/bash
# Backup /etc/hello, /opt/hello, konfigurasi nginx + dump sqlite. Retention 7 hari.
set -euo pipefail

BACKUP_DIR=/var/backups/hello
RETENTION_DAYS=7
STAMP=$(date +%F_%H%M)
ARCHIVE="$BACKUP_DIR/hello-$STAMP.tar.gz"

mkdir -p "$BACKUP_DIR"
sqlite3 /opt/hello/db/app.db ".backup '$BACKUP_DIR/app-$STAMP.db'"

tar czf "$ARCHIVE" \
    /etc/hello \
    /opt/hello \
    /etc/nginx/sites-available/hello.conf \
    "$BACKUP_DIR/app-$STAMP.db" 2>/dev/null

sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' -mtime +"$RETENTION_DAYS" -delete
find "$BACKUP_DIR" -maxdepth 1 -name 'app-*.db' -mtime +"$RETENTION_DAYS" -delete

echo "$(date -Is) OK $ARCHIVE $(stat -c%s "$ARCHIVE") bytes"
SH
chmod 750 /usr/local/bin/hello-backup.sh
/usr/local/bin/hello-backup.sh
echo "--- isi backup dir ---"
ls -la /var/backups/hello
echo "--- verifikasi arsip ---"
sha256sum -c /var/backups/hello/*.tar.gz.sha256
tar tzf /var/backups/hello/hello-*.tar.gz | head -6

echo "=== [5] cron.d ==="
cat > /etc/cron.d/hello-backup <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
30 2 * * * root /usr/local/bin/hello-backup.sh >> /var/log/hello-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/hello-backup
cat /etc/cron.d/hello-backup
grep -E 'hello-backup|CRON' /var/log/syslog 2>/dev/null | tail -2
ls -l /var/spool/cron/crontabs/ 2>&1
echo "--- simulasi jalan via cron (run-parts replacement: jalankan manual sebagai root) ---"
/usr/local/bin/hello-backup.sh; tail -2 /var/log/hello-backup.log 2>/dev/null

echo "=== [6] simulasi disaster recovery ==="
echo "--- hapus app.py, service harus gagal ---"
mv /opt/hello/app.py /root/app.py.hilang
systemctl restart hello; sleep 2; systemctl is-active hello; systemctl status hello --no-pager | sed -n '4,8p'
echo "--- restore dari arsip terbaru ---"
LATEST=$(ls -t /var/backups/hello/hello-*.tar.gz | head -1); echo "arsip: $LATEST"
tar xzf "$LATEST" -C / --strip-components=0 opt/hello/app.py
ls -l /opt/hello/app.py
systemctl restart hello; sleep 2; systemctl is-active hello
curl -s http://127.0.0.1:8080/ ; echo
echo "--- bandingkan file lama vs hasil restore ---"
diff /root/app.py.hilang /opt/hello/app.py && echo "IDENTIK"
mv /root/app.py.hilang /root/app.py.hilang.bak
echo DONE
