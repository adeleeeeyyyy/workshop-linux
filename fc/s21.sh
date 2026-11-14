#!/bin/bash
set -u
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

MSG="$(date -Is) OK $ARCHIVE $(stat -c%s "$ARCHIVE") bytes"
echo "$MSG"
/usr/local/bin/notify.sh "backup OK: $(basename "$ARCHIVE")" \
  || echo "alert gagal" >> /var/log/hello-backup.log
SH
chmod 750 /usr/local/bin/hello-backup.sh
echo "=== jalankan versi final ==="
/usr/local/bin/hello-backup.sh
echo "=== isi arsip ==="
tar tzf "$(ls -t /var/backups/hello/hello-*.tar.gz | head -1)"
echo "=== sha ==="
sha256sum -c "$(ls -t /var/backups/hello/*.sha256 | head -1)"
echo "=== ukuran & daftar ==="
ls -la /var/backups/hello | tail -4
echo DONE
