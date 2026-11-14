#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive

echo "=== [1] ufw allow 80,443 ==="
ufw allow 80,443/tcp 2>&1 | tail -2
ufw status | sed -n '1,12p'

echo "=== [2] self-signed cert ==="
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /etc/ssl/private/hello.lab.test.key \
  -out /etc/ssl/certs/hello.lab.test.crt \
  -subj "/C=ID/ST=DKI/L=Jakarta/O=Lab/CN=hello.lab.test" \
  -addext "subjectAltName=DNS:hello.lab.test" 2>&1 | tail -2
chmod 600 /etc/ssl/private/hello.lab.test.key
openssl x509 -in /etc/ssl/certs/hello.lab.test.crt -noout -subject -dates -ext subjectAltName

echo "=== [3] tuning snippet (gzip + cache + rate limit) ==="
mkdir -p /var/cache/nginx/hello
cat > /etc/nginx/conf.d/tuning.conf <<'NGX'
gzip on;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;
gzip_vary on;

proxy_cache_path /var/cache/nginx/hello levels=1:2 keys_zone=hello_cache:10m max_size=100m inactive=10m use_temp_path=off;

limit_req_zone $binary_remote_addr zone=hello_rl:10m rate=10r/s;
limit_conn_zone $binary_remote_addr zone=hello_conn:10m;
limit_req_status 429;
NGX
nginx -t 2>&1 | tail -1

echo "=== [4] tls + tuned site ==="
cat > /etc/nginx/sites-available/hello.conf <<'NGX'
server {
    listen 80;
    server_name hello.lab.test;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name hello.lab.test;

    ssl_certificate     /etc/ssl/certs/hello.lab.test.crt;
    ssl_certificate_key /etc/ssl/private/hello.lab.test.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/hello.access.log;
    error_log  /var/log/nginx/hello.error.log;

    limit_req  zone=hello_rl burst=20 nodelay;
    limit_conn hello_conn 20;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_cache hello_cache;
        proxy_cache_valid 200 10s;
        proxy_cache_use_stale error timeout updating;
        add_header X-Cache-Status $upstream_cache_status always;
    }
}
NGX
nginx -t 2>&1 | tail -1
systemctl reload nginx; sleep 1
echo "=== [5] https local (self-signed) ==="
curl -sk https://hello.lab.test/; echo
curl -sk -D- -o /dev/null https://hello.lab.test/ | grep -Ei 'HTTP/|x-cache-status|content-encoding'
echo "--- redirect 80->443 ---"
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://hello.lab.test/
echo "--- curl without -k (must fail) ---"
curl -s https://hello.lab.test/ 2>&1 | head -3; echo "rc=$?"
echo "=== [6] cache HIT/MISS x2 ==="
curl -sk -o /dev/null -D- https://hello.lab.test/ | grep -i x-cache-status
curl -sk -o /dev/null -D- https://hello.lab.test/ | grep -i x-cache-status
echo "=== [7] gzip test ==="
curl -sk -H 'Accept-Encoding: gzip' -D- -o /dev/null https://hello.lab.test/ | grep -Ei 'content-encoding|content-length|vary'
echo "=== [8] wrk load test 10s ==="
which wrk || apt-get install -y wrk 2>&1 | tail -2
wrk -t2 -c10 -d10s --latency https://hello.lab.test/ -s /dev/null 2>/dev/null || wrk -t2 -c10 -d10s --latency https://hello.lab.test/ 2>&1 | head -20
echo "=== [9] rate limit test (ab 100 req concurrency 20) ==="
apt-get install -y apache2-utils 2>&1 | tail -1
ab -k -q -n 200 -c 20 https://hello.lab.test/ 2>&1 | grep -E 'Complete requests|Non-2xx|Requests per second|Failed'
echo "--- count 429 in access log ---"
grep -c ' 429 ' /var/log/nginx/hello.access.log || true
echo "=== [10] nginx -T key lines ==="
nginx -T 2>/dev/null | grep -cE 'gzip on|limit_req zone|proxy_cache hello_cache'
echo DONE
