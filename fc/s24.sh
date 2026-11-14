#!/bin/bash
set -u
echo "=== [0] bersihkan snippet lama dari uji topik 2 ==="
mkdir -p /root/snippet-backup
[ -f /etc/nginx/conf.d/tuning.conf ] && mv /etc/nginx/conf.d/tuning.conf /root/snippet-backup/
[ -f /etc/nginx/sites-enabled/hello.conf ] && mv /etc/nginx/sites-enabled/hello.conf /root/snippet-backup/
[ -f /etc/nginx/conf.d/stateless-tuning.conf ] && mv /etc/nginx/conf.d/stateless-tuning.conf /root/snippet-backup/
ls /etc/nginx/conf.d/ /etc/nginx/sites-enabled/

echo "=== [1] gzip pada static file 4096 byte ==="
cat > /etc/nginx/conf.d/stateless-tuning.conf <<'NGX'
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript;
gzip_vary on;
proxy_cache_path /var/cache/nginx/site levels=1:2 keys_zone=site_cache:10m max_size=50m inactive=10m use_temp_path=off;
limit_req_zone $binary_remote_addr zone=site_rl:10m rate=10r/s;
limit_req_status 429;
NGX
nginx -t 2>&1 | tail -2
systemctl reload nginx; sleep 1; systemctl is-active nginx
curl -s -H 'Host: app.lab.test' http://127.0.0.1:8081/; echo
curl -s -H 'Host: app.lab.test' http://127.0.0.1:8081/api/; echo
curl -s -H 'Accept-Encoding: gzip' -H 'Host: app.lab.test' -o /dev/null -w 'gzip=%{size_download}\n' http://127.0.0.1:8081/big.txt
curl -s -H 'Host: app.lab.test' -o /dev/null -w 'plain=%{size_download}\n' http://127.0.0.1:8081/big.txt
curl -s -H 'Accept-Encoding: gzip' -H 'Host: app.lab.test' -D- -o /dev/null http://127.0.0.1:8081/big.txt | grep -Ei 'content-encoding|vary'

echo "=== [2] cache /cached/ ==="
for i in 1 2 3; do curl -s -H 'Host: app.lab.test' -o /dev/null -D- http://127.0.0.1:8081/cached/ | grep -i x-cache-status; done

echo "=== [3] wrk: nginx static vs python backend ==="
wrk -t2 -c20 -d5s -H 'Host: app.lab.test' http://127.0.0.1:8081/big.txt 2>&1 | grep -E 'requests in|Requests/sec'
wrk -t1 -c5 -d5s http://127.0.0.1:8000/ 2>&1 | grep -E 'requests in|Requests/sec|Socket errors'

echo "=== [4] rate limit: vhost dengan limit_req ==="
cat > /etc/nginx/sites-available/stateless.conf <<'NGX'
server {
    listen 8081;
    server_name app.lab.test;

    root  /srv/site;
    index index.html;

    limit_req  zone=site_rl burst=20 nodelay;

    location /    { try_files $uri $uri/ =404; }
    location /api/ { proxy_pass http://127.0.0.1:8000/; }
    location /cached/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_cache site_cache;
        proxy_cache_valid 200 10s;
        add_header X-Cache-Status $upstream_cache_status always;
    }
}
NGX
nginx -t 2>&1 | tail -1; systemctl reload nginx; sleep 1
wrk -t2 -c20 -d5s -H 'Host: app.lab.test' http://127.0.0.1:8081/big.txt 2>&1 | grep -E 'requests in|Non-2xx|Requests/sec'
grep -c ' 429 ' /var/log/nginx/access.log 2>/dev/null || true
sleep 3
curl -s -H 'Host: app.lab.test' -o /dev/null -w 'after_3s=%{http_code}\n' http://127.0.0.1:8081/
echo DONE
