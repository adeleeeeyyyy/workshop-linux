#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive
echo "=== [3] tuning snippet (tanpa 'gzip on' — sudah ada di nginx.conf Debian) ==="
mkdir -p /var/cache/nginx/hello
cat > /etc/nginx/conf.d/tuning.conf <<'NGX'
# gzip on; sudah aktif di /etc/nginx/nginx.conf (Debian) -> jangan diulang
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;
gzip_vary on;

proxy_cache_path /var/cache/nginx/hello levels=1:2 keys_zone=hello_cache:10m max_size=100m inactive=10m use_temp_path=off;

limit_req_zone $binary_remote_addr zone=hello_rl:10m rate=10r/s;
limit_conn_zone $binary_remote_addr zone=hello_conn:10m;
limit_req_status 429;
NGX
nginx -t 2>&1 | tail -2
systemctl reload nginx; sleep 1; systemctl is-active nginx

echo "=== [5] https local ==="
curl -sk https://hello.lab.test/; echo
curl -sk -D- -o /dev/null https://hello.lab.test/ | grep -Ei 'HTTP/|x-cache-status|x-cache'
echo "--- redirect 80->443 ---"
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://hello.lab.test/
echo "--- curl tanpa -k ---"
curl -sS https://hello.lab.test/ 2>&1 | head -3
echo "=== [6] cache status x3 ==="
for i in 1 2 3; do curl -sk -o /dev/null -D- https://hello.lab.test/ | grep -i x-cache-status; done
echo "=== [7] gzip ==="
curl -sk -H 'Accept-Encoding: gzip' -D- -o /dev/null https://hello.lab.test/ | grep -Ei 'content-encoding|vary'
curl -sk -H 'Accept-Encoding: gzip' -o /dev/null -w 'size_gzip=%{size_download}\n' https://hello.lab.test/
curl -sk -o /dev/null -w 'size_plain=%{size_download}\n' https://hello.lab.test/
echo "=== [8] wrk 10s c10 ==="
wrk -t2 -c10 -d10s --latency https://hello.lab.test/ 2>&1 | head -14
echo "=== [9] ab 200 req c20 (rate limit 10r/s) ==="
ab -q -n 200 -c 20 https://hello.lab.test/ 2>&1 | grep -E 'Complete requests|Non-2xx|Requests per second|Time per request' | head -5
echo "--- 429 count in access log ---"
grep -c ' 429 ' /var/log/nginx/hello.access.log
echo "--- sample 429 line ---"
grep ' 429 ' /var/log/nginx/hello.access.log | tail -1
echo "=== [10] verify directives loaded ==="
nginx -T 2>/dev/null | grep -cE 'gzip_comp_level 5|limit_req zone=hello_rl|proxy_cache hello_cache'
echo DONE
