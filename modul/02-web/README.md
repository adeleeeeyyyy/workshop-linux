# Modul 2: Web, Service & Performance Readiness

Setiap sub-topik berdiri sendiri. Backend contoh disediakan di dalam tiap
sub-topik, jadi tidak ada ketergantungan antar bagian.

Total 95 menit untuk keempat sub-topik.

Konvensi:
- `<IP-VM>` IP VM, `<domain>` nama host contoh `app.lab.test`.
- Semua perintah sebagai `root`.
- OS acuan Debian 13.1, nginx 1.26.3, systemd 257.

---

## 2.1 Menjalankan aplikasi sebagai systemd service · 25 menit

Hasil: aplikasi jalan otomatis saat boot, restart sendiri saat crash, log masuk
journal, dan berjalan sebagai user non-root.

Prasyarat: root, `python3` terpasang (`apt-get install -y python3`), port 8080
kosong (`ss -tlnp | grep 8080` tanpa hasil).

```bash
# 1. user khusus aplikasi
useradd --system --no-create-home --shell /usr/sbin/nologin appsvc

# 2. aplikasi contoh (Python stdlib, tanpa dependency)
mkdir -p /opt/demo /etc/demo
cat > /opt/demo/app.py <<'PY'
#!/usr/bin/env python3
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
START = time.time()

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"path": self.path,
                           "uptime_s": round(time.time() - START, 1)}).encode()
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

# 3. nilai yang berubah per lingkungan, tidak masuk unit file
printf 'PORT=8080\n' > /etc/demo/demo.env
chmod 600 /etc/demo/demo.env

# 4. unit file
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

# daemon-reload wajib tiap kali unit file berubah
systemctl daemon-reload
systemctl enable --now demo
```

Verifikasi:

```bash
systemctl is-active demo                 # active
systemctl show -p User -p MainPID --value demo
curl -s http://127.0.0.1:8080/           # JSON dengan uptime_s
ss -tlnp | grep 8080                     # listen di 127.0.0.1, dipegang appsvc

kill -9 $(systemctl show -p MainPID --value demo); sleep 5
systemctl show -p NRestarts --value demo # 1
systemctl is-active demo                 # active
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `status=203/EXEC` | path di `ExecStart` salah | cek `ls -l /usr/bin/python3 /opt/demo/app.py` |
| `status=200/CHDIR` | `WorkingDirectory` tidak ada | buat direktori, cek permission |
| Service `activating` terus, `MainPID` 0 | port 8080 sudah dipakai proses lain | `ss -tlnp \| grep 8080`, hentikan proses itu atau ganti `PORT` |
| Restart terus tanpa henti | aplikasi crash karena config | `journalctl -u demo -n 30`, perbaiki config |
| Gagal menulis file | `ProtectSystem=strict` membuat FS read-only | tambahkan `ReadWritePaths=/path` |

Jebakan:
- `Restart=always` ikut me-restart saat stop manual yang tidak bersih. Pakai
  `on-failure` untuk service normal.
- `ProtectSystem=strict` membaca seluruh filesystem sebagai read-only kecuali
  `/dev`, `/proc`, `/sys`. Aplikasi yang menulis file butuh `ReadWritePaths`.
- Lupa `daemon-reload` membuat perubahan unit tidak berefek.

---

## 2.2 Reverse proxy nginx dan pemetaan domain lokal · 20 menit

Hasil: `http://<domain>` dilayani nginx dan diteruskan ke aplikasi di port 8080.

Prasyarat: root, `python3` dan `nginx` terpasang. Backend bisa aplikasi apa pun
di `127.0.0.1:8080`. Kalau belum ada, pakai server contoh berikut.

```bash
# backend contoh sementara (2 detik setelah dijalankan)
mkdir -p /srv/backend
printf 'backend ok\n' > /srv/backend/index.html
cd /srv/backend && nohup python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 &
sleep 2
curl -s http://127.0.0.1:8080/
```

Pasang nginx dan vhost:

```bash
apt-get install -y nginx

cat > /etc/nginx/sites-available/app.conf <<'NGX'
server {
    listen 80;
    server_name <domain>;

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
nginx -t
systemctl reload nginx

# pemetaan nama lokal, dan buka port di firewall
echo '127.0.0.1 <domain>' >> /etc/hosts
ufw allow 80/tcp      # kalau UFW terpasang
```

Verifikasi:

```bash
getent hosts <domain>                                  # 127.0.0.1 <domain>
curl -s http://<domain>/                               # backend ok
curl -s -o /dev/null -w '%{http_code}\n' http://<IP-VM>/   # 200 dari PC
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `502 Bad Gateway` | backend mati atau port beda | `ss -tlnp \| grep 8080`, cek `proxy_pass` |
| Halaman nginx default muncul | vhost lain menang | `ls -l /etc/nginx/sites-enabled/`, hapus symlink `default` |
| `Job for nginx.service failed` | `nginx -t` gagal | baca baris `[emerg]`, perbaiki, reload lagi |
| Timeout dari PC | UFW menutup port 80 | `ufw allow 80/tcp` |

Jebakan:
- `server_name` hanya cocok kalau request membawa header `Host` yang sama. Uji
  tanpa `/etc/hosts` bisa pakai `curl -H 'Host: <domain>' http://127.0.0.1/`.
- Tanpa `X-Forwarded-For`, aplikasi melihat semua klien sebagai `127.0.0.1`.
  Log audit dan rate limit per IP jadi tidak berguna.
- `systemctl reload nginx` gagal menyisakan worker lama tetap jalan. Situs
  terlihat normal padahal config baru belum aktif. Selalu baca output
  `nginx -t`.

---

## 2.3 HTTPS · 20 menit

Hasil: situs dilayani HTTPS. Self-signed untuk lab internal, Let's Encrypt untuk
domain publik.

Prasyarat: nginx terpasang (`apt-get install -y nginx`), port 80 dan 443 terbuka
di firewall.

### Self-signed (bisa dijalankan sekarang)

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /etc/ssl/private/<domain>.key \
  -out /etc/ssl/certs/<domain>.crt \
  -subj "/CN=<domain>" \
  -addext "subjectAltName=DNS:<domain>"
chmod 600 /etc/ssl/private/<domain>.key

# isi statis untuk uji tanpa backend
mkdir -p /srv/site
printf 'https ok\n' > /srv/site/index.html

cat > /etc/nginx/sites-available/tls.conf <<'NGX'
server {
    listen 80;
    server_name <domain>;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name <domain>;

    ssl_certificate     /etc/ssl/certs/<domain>.crt;
    ssl_certificate_key /etc/ssl/private/<domain>.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root  /srv/site;
    index index.html;
}
NGX

ln -sf /etc/nginx/sites-available/tls.conf /etc/nginx/sites-enabled/tls.conf
nginx -t && systemctl reload nginx
ufw allow 443/tcp     # kalau UFW terpasang
```

Verifikasi:

```bash
openssl x509 -in /etc/ssl/certs/<domain>.crt -noout -subject -ext subjectAltName
curl -sk https://<domain>/                                      # https ok
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://<domain>/   # 301 ke https
curl -s https://<domain>/                                       # error 60, self-signed
```

`http2 on;` sintaks nginx 1.25.1 ke atas. Di nginx 1.24 ke bawah tulis
`listen 443 ssl http2;`.

### Let's Encrypt (DOKUMENTASI, butuh domain publik)

```bash
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d <domain> -d www.<domain>
certbot renew --dry-run
systemctl list-timers 'certbot*'
```

Syarat: DNS `<domain>` mengarah ke IP publik VM, port 80 bisa dijangkau dari
internet. Domain yang hanya ada di `/etc/hosts` tidak bisa divalidasi.

### Cloudflare Tunnel (DOKUMENTASI, tanpa IP publik)

```bash
curl -fsSL -o /tmp/cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i /tmp/cloudflared.deb
cloudflared tunnel login
cloudflared tunnel create app
cloudflared tunnel route dns app <domain>
cloudflared service install
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `curl: (60) self-signed certificate` | normal untuk self-signed | pakai `-k` di lab |
| `nginx -t` gagal karena `http2` | nginx versi lama | `listen 443 ssl http2;` |
| Browser menolak cert meski `CN` benar | SAN tidak ada | tambahkan `-addext "subjectAltName=DNS:<domain>"` |
| Certbot gagal validasi | port 80 tertutup atau DNS salah | cek `ufw status`, `getent hosts <domain>` |

Jebakan:
- `-nodes` membuat key tanpa passphrase. Itu syarat nginx bisa start saat boot,
  jadi file key wajib mode 600 dan milik root.
- Jangan pakai `curl -k` di produksi. Itu mematikan verifikasi.
- Redirect 80 ke 443 harus di vhost yang sama. Kalau `default` masih aktif,
  request bisa mendarat di sana.

---

## 2.4 gzip, cache, dan rate limit · 30 menit

Hasil: respons dikompres, konten di-cache, dan request berlebih ditolak 429.

Prasyarat: nginx terpasang, port 80 terbuka. Backend contoh disediakan di bawah.

```bash
# halaman statis 4 KB untuk uji gzip
mkdir -p /srv/site
printf 'index\n' > /srv/site/index.html
yes 'data uji gzip untuk nginx' | head -c 4096 > /srv/site/big.txt

# backend contoh untuk uji cache
mkdir -p /srv/backend
printf 'backend ok\n' > /srv/backend/index.html
cd /srv/backend && nohup python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 &
sleep 2
```

Satu file untuk semua direktif. Dua file yang sama-sama menulis `gzip_comp_level`
membuat `nginx -t` gagal `directive is duplicate`.

```bash
cat > /etc/nginx/conf.d/tuning.conf <<'NGX'
# gzip on; sudah ada di /etc/nginx/nginx.conf (paket Debian). Jangan diulang
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript;
gzip_vary on;

proxy_cache_path /var/cache/nginx/site levels=1:2 keys_zone=site_cache:10m max_size=50m inactive=10m use_temp_path=off;

limit_req_zone $binary_remote_addr zone=site_rl:10m rate=10r/s;
limit_req_status 429;
NGX

cat > /etc/nginx/sites-available/app.conf <<'NGX'
server {
    listen 80;
    server_name <domain>;

    root  /srv/site;
    index index.html;

    limit_req zone=site_rl burst=20 nodelay;

    location /      { try_files $uri $uri/ =404; }

    location /api/  { proxy_pass http://127.0.0.1:8080/; }

    location /cached/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_cache site_cache;
        proxy_cache_valid 200 10s;
        add_header X-Cache-Status $upstream_cache_status always;
    }
}
NGX

ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
nginx -t && systemctl reload nginx
echo '127.0.0.1 <domain>' >> /etc/hosts
```

Direktori cache dibuat sendiri oleh nginx saat start.

Verifikasi:

```bash
# gzip: 4096 byte jadi sekitar 72 byte
curl -s -H 'Accept-Encoding: gzip' -o /dev/null -w 'gzip=%{size_download}\n' http://<domain>/big.txt
curl -s -o /dev/null -w 'plain=%{size_download}\n' http://<domain>/big.txt
curl -s -H 'Accept-Encoding: gzip' -D- -o /dev/null http://<domain>/big.txt | grep -i content-encoding

# cache: MISS lalu HIT
for i in 1 2 3; do curl -s -o /dev/null -D- http://<domain>/cached/ | grep -i x-cache-status; done

# rate limit: jalankan load, lalu lihat 429
apt-get install -y wrk apache2-utils
wrk -t2 -c20 -d5s http://<domain>/big.txt | grep -E 'requests in|Non-2xx|Requests/sec'
grep -c ' 429 ' /var/log/nginx/access.log
```

Angka acuan di Debian 13.1, 1 vCPU: 4096 byte menjadi 72 byte, cache urutan
`MISS, HIT, HIT`, 43.588 dari 43.658 request dapat 429, dan request tunggal
kembali 200 setelah 3 detik.

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `"gzip" directive is duplicate` | `gzip on;` ditulis dua kali | hapus salah satu, sisakan yang di `nginx.conf` |
| `gzip_comp_level` duplicate | dua file di `conf.d` menulis direktif sama | gabungkan ke satu file |
| `X-Cache-Status` selalu MISS | respons punya `Set-Cookie` atau `Cache-Control: no-store` | sesuaikan `proxy_cache_valid`, cek header backend |
| Semua request 429 setelah load test | token rate limit habis | tunggu 3 detik, atau naikkan `burst` |
| Respons kecil tidak terkompres | di bawah `gzip_min_length 256` | normal, kompresi justru memperbesar |

Jebakan:
- `limit_req_status` default 503. Monitoring akan membaca itu sebagai server
  down. Pakai 429.
- Rate limit dihitung per IP. Setelah wrk, IP Anda sendiri masih kena 429 selama
  beberapa detik.
- `systemctl restart nginx` tidak mengosongkan cache. Isinya di
  `/var/cache/nginx/site`, kedaluwarsa mengikuti `proxy_cache_valid`.
- Kompresi hanya untuk tipe di `gzip_types`. Tambahkan sendiri kalau backend
  mengirim tipe lain.
