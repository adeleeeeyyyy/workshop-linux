#!/bin/bash
set -u
echo "=== [1] tambah endpoint /big (2 KB) untuk uji gzip ==="
cat > /opt/hello/app.py <<'PY'
#!/usr/bin/env python3
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
START = time.time()

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        data = {"app": "hello", "path": self.path,
                "uptime_s": round(time.time() - START, 1),
                "host": os.uname().nodename}
        if self.path.startswith("/big"):
            data["blob"] = "x" * 2048
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *a):
        print("%s %s" % (self.address_string(), fmt % a), flush=True)

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
chown ops:ops /opt/hello/app.py
systemctl restart hello; sleep 2; systemctl is-active hello
curl -s http://127.0.0.1:8080/big | wc -c

echo "=== [2] gzip on /big ==="
curl -sk -H 'Accept-Encoding: gzip' -o /dev/null -w 'gzip_bytes=%{size_download}\n' https://hello.lab.test/big
curl -sk -o /dev/null -w 'plain_bytes=%{size_download}\n' https://hello.lab.test/big
curl -sk -H 'Accept-Encoding: gzip' -D- -o /dev/null https://hello.lab.test/big | grep -Ei 'content-encoding|vary'
echo "--- tanpa gzip_min_length (respons kecil) ---"
curl -sk -H 'Accept-Encoding: gzip' -D- -o /dev/null https://hello.lab.test/ | grep -Ei 'content-encoding' || echo "no content-encoding (di bawah gzip_min_length=256)"

echo "=== [3] baseline wrk TANPA rate limit ==="
cp /etc/nginx/sites-available/hello.conf /root/hello.conf.withlimit
python3 - <<'PY'
p = "/etc/nginx/sites-available/hello.conf"
s = open(p).read()
s = s.replace("    limit_req  zone=hello_rl burst=20 nodelay;\n", "")
s = s.replace("    limit_conn hello_conn 20;\n", "")
open(p, "w").write(s)
PY
nginx -t 2>&1 | tail -1; systemctl reload nginx; sleep 1
wrk -t2 -c20 -d10s --latency https://hello.lab.test/ 2>&1 | grep -E 'Latency|Req/Sec|requests in|Non-2xx|Requests/sec|Transfer/sec'

echo "=== [4] aktifkan lagi rate limit ==="
cp /root/hello.conf.withlimit /etc/nginx/sites-available/hello.conf
nginx -t 2>&1 | tail -1; systemctl reload nginx; sleep 1
echo "--- wrk 10s c20 dengan limit_req ---"
wrk -t2 -c20 -d10s https://hello.lab.test/ 2>&1 | grep -E 'requests in|Non-2xx|Requests/sec|Socket errors'
echo "--- 429 sample ---"
grep ' 429 ' /var/log/nginx/hello.access.log | tail -1
echo "--- request 1x dari host lain: harus 200 ---"
curl -sk -o /dev/null -w '%{http_code}\n' https://hello.lab.test/
echo DONE
