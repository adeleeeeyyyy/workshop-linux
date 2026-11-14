#!/bin/bash
set -u
echo "=== [1] tulis ulang hello-backup.sh PERSIS seperti di modul ==="
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
    etc/nginx/sites-available/hello.conf \
    "var/backups/hello/app-$STAMP.db"

sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

# retensi
find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz'  -mtime +"$RETENTION_DAYS" -delete
find "$BACKUP_DIR" -maxdepth 1 -name 'app-*.db'  -mtime +"$RETENTION_DAYS" -delete
find "$BACKUP_DIR" -maxdepth 1 -name '*.sha256'  -mtime +"$RETENTION_DAYS" -delete

MSG="$(date -Is) OK $ARCHIVE $(stat -c%s "$ARCHIVE") bytes"
echo "$MSG"
/usr/local/bin/notify.sh "backup OK: $(basename "$ARCHIVE")" \
  || echo "alert gagal" >> /var/log/hello-backup.log
SH
chmod 750 /usr/local/bin/hello-backup.sh
echo "--- jalankan ---"
/usr/local/bin/hello-backup.sh
echo "--- isi arsip ---"
tar tzf $(ls -t /var/backups/hello/hello-*.tar.gz | head -1)
echo "--- verifikasi sha ---"
sha256sum -c /var/backups/hello/*.sha256 | tail -2

echo "=== [2] uji retensi: file tua 10 hari ==="
touch -d '10 days ago' /var/backups/hello/hello-2020-01-01_0000.tar.gz
touch -d '10 days ago' /var/backups/hello/app-2020-01-01_0000.db
ls /var/backups/hello/
echo "--- uji kering (print) ---"
find /var/backups/hello -maxdepth 1 -name '*.tar.gz' -mtime +7 -print
echo "--- jalankan backup lagi (retensi aktif) ---"
/usr/local/bin/hello-backup.sh
ls /var/backups/hello/

echo "=== [3] env -i (simulasi cron) ==="
env -i /bin/bash -c '/usr/local/bin/hello-backup.sh'; echo "rc=$?"

echo "=== [4] cron: terbaca & tanpa error? ==="
systemctl is-active cron
journalctl -u cron -n 12 --no-pager | tail -12
tail -3 /var/log/hello-backup.log

echo "=== [5] restore selektif dari arsip baru ==="
LATEST=$(ls -t /var/backups/hello/hello-*.tar.gz | head -1); echo "$LATEST"
mv /opt/hello/app.py /root/app2.hilang
systemctl restart hello; sleep 2; systemctl is-active hello
tar xzf "$LATEST" -C / opt/hello/app.py
systemctl restart hello; sleep 2; systemctl is-active hello
curl -s http://127.0.0.1:8080/; echo
diff /root/app2.hilang /opt/hello/app.py && echo IDENTIK
echo DONE
