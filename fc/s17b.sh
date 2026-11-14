#!/bin/bash
set -u
echo "=== [0] cleanup ==="
pkill -f capture.py 2>/dev/null; sleep 1; ss -tlnp | grep 9099 || echo "9099 bebas"

echo "=== [1] env file + notify.sh (variabel bisa dioverride dari environment) ==="
cat > /etc/alert.env <<'ENV'
# chmod 600, jangan pernah commit ke git
PROVIDER=${PROVIDER:-telegram}
TG_TOKEN=${TG_TOKEN:-000000:FAKE_TOKEN_UNTUK_UJI_LOKAL}
TG_CHAT=${TG_CHAT:-123456789}
TG_API=${TG_API:-https://api.telegram.org}
DISCORD_WEBHOOK=${DISCORD_WEBHOOK:-}
ENV
chmod 600 /etc/alert.env; ls -l /etc/alert.env

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

cat > /tmp/capture.py <<'PY'
import http.server, sys
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

start_capture() { pkill -f capture.py 2>/dev/null; sleep 0.5; setsid python3 /tmp/capture.py >/dev/null 2>&1 < /dev/null & sleep 1; }
show_capture() { sleep 1; cat /tmp/captured.txt 2>&1; echo; }

echo "=== [2] kirim alert (TG_API -> capture lokal) ==="
start_capture
TG_API=http://127.0.0.1:9099 /usr/local/bin/notify.sh "backup selesai: hello.tar.gz 1.4 KB"
show_capture

echo "=== [3] check-disk ambang 1 (harus kirim) ==="
start_capture
THRESHOLD=1 TG_API=http://127.0.0.1:9099 /usr/local/bin/check-disk.sh
show_capture

echo "=== [4] check-disk ambang 99 (harus senyap) ==="
THRESHOLD=99 /usr/local/bin/check-disk.sh; echo "rc=$? (senyap = benar)"
echo "=== [5] disk nyata ==="
df --output=pcent / | tail -1 | tr -dc '0-9'; echo "%"

echo "=== [6] alert dari script backup ==="
start_capture
TG_API=http://127.0.0.1:9099 /usr/local/bin/hello-backup.sh
show_capture
pkill -f capture.py 2>/dev/null
echo DONE
