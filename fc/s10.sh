#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive

echo "=== [1] app dir + code ==="
mkdir -p /opt/hello
cat > /opt/hello/app.py <<'PY'
#!/usr/bin/env python3
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
START = time.time()

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"app": "hello", "path": self.path,
                           "uptime_s": round(time.time() - START, 1),
                           "host": os.uname().nodename}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *a):
        print("%s %s" % (self.address_string(), fmt % a), flush=True)

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
chown -R ops:ops /opt/hello
ls -la /opt/hello

echo "=== [2] env file 600 ==="
mkdir -p /etc/hello
printf 'PORT=8080\n' > /etc/hello/hello.env
chmod 600 /etc/hello/hello.env
ls -l /etc/hello/hello.env

echo "=== [3] unit ==="
cat > /etc/systemd/system/hello.service <<'UNIT'
[Unit]
Description=hello demo API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ops
Group=ops
WorkingDirectory=/opt/hello
EnvironmentFile=/etc/hello/hello.env
ExecStart=/usr/bin/python3 /opt/hello/app.py
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
systemctl enable --now hello 2>&1 | tail -2
sleep 2
systemctl is-active hello; systemctl show -p MainPID -p User --value hello
echo "=== [4] curl local ==="
curl -s http://127.0.0.1:8080/; echo
curl -s http://127.0.0.1:8080/health; echo
echo "=== [5] ss listening ==="
ss -tlnp | grep 8080
echo "=== [6] restart-on-crash demo ==="
pid=$(systemctl show -p MainPID --value hello); kill -9 "$pid"; sleep 5
systemctl show -p MainPID -p NRestarts --value hello; systemctl is-active hello
echo "=== [7] journal ==="
journalctl -u hello -n 4 --no-pager | tail -4

echo "=== [8] nginx install ==="
apt-get install -y nginx 2>&1 | tail -3
nginx -v; systemctl is-active nginx; ss -tlnp | grep -E ':80|:443'

echo "=== [9] reverse proxy site ==="
cat > /etc/nginx/sites-available/hello.conf <<'NGX'
server {
    listen 80;
    server_name hello.lab.test;

    access_log /var/log/nginx/hello.access.log;
    error_log  /var/log/nginx/hello.error.log;

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
ln -sf /etc/nginx/sites-available/hello.conf /etc/nginx/sites-enabled/hello.conf
nginx -t 2>&1 | tail -2
systemctl reload nginx; sleep 1
echo "=== [10] hosts entry + curl via Host header ==="
grep -q 'hello.lab.test' /etc/hosts || echo '127.0.0.1 hello.lab.test' >> /etc/hosts
getent hosts hello.lab.test
curl -s http://hello.lab.test/; echo
curl -s -o /dev/null -w 'local_status=%{http_code}\n' http://hello.lab.test/

echo "=== [11] ufw state (should block 80 from outside) ==="
ufw status | head -8
echo "=== [12] allow 80,443 SKIPPED (dilakukan manual dari host untuk bukti blokir) ==="
echo DONE
