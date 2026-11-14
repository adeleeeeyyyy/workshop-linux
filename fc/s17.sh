#!/bin/bash
set -u
echo "=== [1] env file + notify.sh ==="
cat > /etc/alert.env <<'ENV'
# chmod 600, jangan commit ke git
PROVIDER=telegram
TG_TOKEN=000000:FAKE_TOKEN_UNTUK_UJI_LOKAL
TG_CHAT=123456789
TG_API=https://api.telegram.org
DISCORD_WEBHOOK=
ENV
chmod 600 /etc/alert.env
ls -l /etc/alert.env

cat > /usr/local/bin/notify.sh <<'SH'
#!/bin/bash
# Kirim 1 baris pesan alert. Pesan diambil dari argumen.
set -euo pipefail
set -a; . /etc/alert.env; set +a
MSG="[$(hostname)] $*"

case "${PROVIDER:-telegram}" in
  telegram)
    curl -fsS -m 10 \
      --data-urlencode "chat_id=${TG_CHAT}" \
      --data-urlencode "text=${MSG}" \
      "${TG_API}/bot${TG_TOKEN}/sendMessage" >/dev/null
    ;;
  discord)
    curl -fsS -m 10 -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg m "$MSG" '{content:$m}')" \
      "${DISCORD_WEBHOOK}" >/dev/null
    ;;
  *) echo "PROVIDER tidak dikenal: $PROVIDER" >&2; exit 1 ;;
esac
echo "sent: $MSG"
SH
chmod 755 /usr/local/bin/notify.sh

cat > /usr/local/bin/check-disk.sh <<'SH'
#!/bin/bash
set -euo pipefail
THRESHOLD=${THRESHOLD:-80}
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "$USED" -ge "$THRESHOLD" ] && /usr/local/bin/notify.sh "DISK ${USED}% (ambang ${THRESHOLD}%)"
exit 0
SH
chmod 755 /usr/local/bin/check-disk.sh
echo "=== [2] capture server lokal untuk bukti payload ==="
cat > /tmp/capture.py <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n).decode()
        with open('/tmp/captured.txt', 'w') as f:
            f.write("PATH=%s\nCT=%s\nBODY=%s\n" % (self.path, self.headers.get('Content-Type'), body))
        self.send_response(200); self.send_header('Content-Length','2'); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 9099), H).handle_request()
PY
python3 /tmp/capture.py &
sleep 1
echo "=== [3] kirim alert (TG_API diarahkan ke capture) ==="
TG_API=http://127.0.0.1:9099 /usr/local/bin/notify.sh "backup selesai: hello-2026-11-14.tar.gz 1.4 KB"
sleep 1
echo "--- payload tertangkap ---"
cat /tmp/captured.txt
echo "=== [4] check-disk: ambang 1 (harus kirim) ==="
python3 /tmp/capture.py &
sleep 1
THRESHOLD=1 TG_API=http://127.0.0.1:9099 /usr/local/bin/check-disk.sh
sleep 1; cat /tmp/captured.txt
echo "=== [5] check-disk: ambang 99 (harus senyap) ==="
THRESHOLD=99 /usr/local/bin/check-disk.sh; echo "rc=$? (tidak ada output = benar)"
echo "=== [6] df nyata ==="
df --output=pcent / | tail -1 | tr -dc '0-9'; echo
echo "=== [7] tambah alert ke script backup ==="
python3 - <<'PY'
p = "/usr/local/bin/hello-backup.sh"
s = open(p).read()
s = s.replace('echo "$(date -Is) OK $ARCHIVE $(stat -c%s "$ARCHIVE") bytes"',
 'MSG="$(date -Is) OK $ARCHIVE $(stat -c%s "$ARCHIVE") bytes"\necho "$MSG"\n/usr/local/bin/notify.sh "backup OK: $(basename "$ARCHIVE")" || echo "alert gagal" >> /var/log/hello-backup.log')
open(p, "w").write(s)
PY
tail -5 /usr/local/bin/hello-backup.sh
echo "=== [8] jalankan backup dengan alert ke capture ==="
python3 /tmp/capture.py &
sleep 1
TG_API=http://127.0.0.1:9099 /usr/local/bin/hello-backup.sh
sleep 1; cat /tmp/captured.txt
echo "=== [9] cron entry check-disk ==="
cat > /etc/cron.d/hello-diskcheck <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
*/15 * * * * root /usr/local/bin/check-disk.sh
CRON
cat /etc/cron.d/hello-diskcheck
echo DONE
