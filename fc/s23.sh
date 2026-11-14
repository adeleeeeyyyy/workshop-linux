#!/bin/bash
# fact-check untuk versi stateless: backend stand-in, static root, cache, wrk
set -u
echo "=== [1] backend stand-in: python3 -m http.server ==="
mkdir -p /srv/static
printf 'halo dari python http.server\n' > /srv/static/index.html
cd /srv/static && nohup python3 -m http.server 8000 --bind 127.0.0.1 >/var/log/pyhttp.log 2>&1 &
sleep 2
curl -s http://127.0.0.1:8000/
ss -tlnp | grep 8000

echo "=== [2] nginx static vhost + file besar untuk uji gzip ==="
mkdir -p /srv/site
yes 'data uji gzip untuk nginx' | head -c 4096 > /srv/site/big.txt
printf 'index\n' > /srv/site/index.html
cat > /etc/nginx/sites-available/stateless.conf <<'NGX'
server {
    listen 8081;
    server_name app.lab.test;

    root  /srv/site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host $host;
    }

    location /cached/ {
        proxy_pass http://127.0.0.1:8000/;
        proxy_cache site_cache;
        proxy_cache_valid 200 10s;
        add_header X-Cache-Status $upstream_cache_status always;
    }
}
NGX
cat > /etc/nginx/conf.d/stateless-tuning.conf <<'NGX'
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript;
gzip_vary on;
proxy_cache_path /var/cache/nginx/site levels=1:2 keys_zone=site_cache:10m max_size=50m inactive=10m use_temp_path=off;
limit_req_zone $binary_remote_addr zone=site_rl:10m rate=10r/s;
limit_req_status 429;
NGX
ln -sf /etc/nginx/sites-available/stateless.conf /etc/nginx/sites-enabled/stateless.conf
nginx -t 2>&1 | tail -2
systemctl reload nginx; sleep 1
echo "--- static ---"; curl -s -H 'Host: app.lab.test' http://127.0.0.1:8081/
echo "--- proxy /api/ ---"; curl -s -H 'Host: app.lab.test' http://127.0.0.1:8081/api/
echo "--- gzip 4096 byte ---"
curl -s -H 'Accept-Encoding: gzip' -o /dev/null -w 'gzip=%{size_download}\n' -H 'Host: app.lab.test' http://127.0.0.1:8081/big.txt
curl -s -o /dev/null -w 'plain=%{size_download}\n' -H 'Host: app.lab.test' http://127.0.0.1:8081/big.txt
echo "--- cache /cached/ ---"
for i in 1 2 3; do curl -s -o /dev/null -D- -H 'Host: app.lab.test' http://127.0.0.1:8081/cached/ | grep -i x-cache-status; done
echo "--- wrk static vs python backend ---"
wrk -t2 -c20 -d5s http://127.0.0.1:8081/big.txt 2>&1 | grep -E 'requests in|Requests/sec'
wrk -t2 -c20 -d5s http://127.0.0.1:8000/ 2>&1 | grep -E 'requests in|Requests/sec|Socket errors|connect'

echo "=== [3] rate limit 429 di vhost stateless (dites terpisah di s24) ==="

echo "=== [4] backup stateless: tar direktori netral ==="
mkdir -p /srv/data
printf 'baris1\nbaris2\n' > /srv/data/app.conf
tar czf /tmp/data-backup.tar.gz -C / srv/data etc/nginx/sites-available/stateless.conf
tar tzf /tmp/data-backup.tar.gz
sha256sum /tmp/data-backup.tar.gz | head -1
echo DONE
