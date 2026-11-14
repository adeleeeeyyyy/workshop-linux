#!/bin/bash
# uji persis seperti modul stateless: 2.1, 2.2 (port 80), 4.2
set -u
echo "########## 2.1 systemd service ##########"
id appsvc >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin appsvc
mkdir -p /opt/demo /etc/demo
cat > /opt/demo/app.py <<'PY'
#!/usr/bin/env python3
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT = int(os.environ.get("PORT", "8080"))
START = time.time()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"path": self.path, "uptime_s": round(time.time() - START, 1)}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *a):
        print(self.address_string(), fmt % a, flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
chown -R appsvc:appsvc /opt/demo
printf 'PORT=8080\n' > /etc/demo/demo.env
chmod 600 /etc/demo/demo.env
cat > /etc/systemd/system/demo.service <<'UNIT'
[Unit]
Description=demo API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=appsvc
Group=appsvc
WorkingDirectory=/opt/demo
EnvironmentFile=/etc/demo/demo.env
ExecStart=/usr/bin/python3 /opt/demo/app.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now demo 2>&1 | tail -1
sleep 2
echo "--- status ---"; systemctl is-active demo
systemctl show -p User -p MainPID --value demo
echo "--- curl ---"; curl -s http://127.0.0.1:8080/; echo
echo "--- ss ---"; ss -tlnp | grep 8080
echo "--- kill -9 + restart ---"
kill -9 $(systemctl show -p MainPID --value demo); sleep 5
systemctl show -p NRestarts --value demo; systemctl is-active demo
journalctl -u demo -n 3 --no-pager | tail -3

echo "########## 2.2 reverse proxy port 80 ##########"
cat > /etc/nginx/sites-available/app.conf <<'NGX'
server {
    listen 80;
    server_name app.lab.test;

    access_log /var/log/nginx/app.access.log;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGX
ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
nginx -t 2>&1 | tail -1
systemctl reload nginx; sleep 1
grep -q 'app.lab.test' /etc/hosts || echo '127.0.0.1 app.lab.test' >> /etc/hosts
getent hosts app.lab.test
curl -s http://app.lab.test/; echo
curl -s -o /dev/null -w 'status=%{http_code}\n' -H 'Host: app.lab.test' http://127.0.0.1/
echo "--- dari laptop (port 80 via UFW) ---"

echo "########## 4.2 backup script ##########"
mkdir -p /srv/data
printf 'konfigurasi penting\n' > /srv/data/app.conf
mkdir -p /srv/data/db
sqlite3 /srv/data/db/app.db "CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, note TEXT);
INSERT INTO t(note) VALUES ('data penting');"
cat > /usr/local/bin/backup.sh <<'SH'
#!/bin/bash
set -euo pipefail
SRC=/srv/data
DB=/srv/data/db/app.db
DEST=/var/backups/app
DAYS=7
STAMP=$(date +%F_%H%M)
ARCHIVE="$DEST/app-$STAMP.tar.gz"
mkdir -p "$DEST"
sqlite3 "$DB" ".backup '$DEST/app-$STAMP.db'"
tar czf "$ARCHIVE" -C / "${SRC#/}"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
find "$DEST" -maxdepth 1 -name '*.tar.gz' -mtime +"$DAYS" -delete
find "$DEST" -maxdepth 1 -name 'app-*.db' -mtime +"$DAYS" -delete
echo "$(date -Is) OK $ARCHIVE $(stat -c%s "$ARCHIVE") bytes"
SH
chmod 750 /usr/local/bin/backup.sh
/usr/local/bin/backup.sh
ls -la /var/backups/app
sha256sum -c /var/backups/app/*.sha256
tar tzf /var/backups/app/app-*.tar.gz
echo "--- restore selektif ---"
sha256sum /srv/data/app.conf
echo 'rusak' > /srv/data/app.conf
LATEST=$(ls -t /var/backups/app/app-*.tar.gz | head -1)
tar xzf "$LATEST" -C / srv/data/app.conf
sha256sum /srv/data/app.conf
cat /srv/data/app.conf
echo "--- env -i ---"
env -i /bin/bash -c '/usr/local/bin/backup.sh'
echo DONE
