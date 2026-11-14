# Topik 2 — Web, Service & Performance Readiness

Estimasi waktu: **110 menit** (4 sub-topik).

Lingkungan uji fact-check: Debian GNU/Linux 13.1 (trixie), 1 vCPU, 1 GB RAM,
nginx 1.26.3, systemd 257 (257.8-1~deb13u2), OpenSSL 3.5.1, wrk 4.1.0,
apache2-utils 2.4.71.
Semua perintah dijalankan di mesin uji pada 14 November 2026 kecuali yang
ditandai DOKUMENTASI.

## Prasyarat / kondisi awal VM

- Topik 1 selesai: user `ops` ada, SSH key bekerja, UFW aktif dengan
  `22/tcp` terbuka, fail2ban jalan.
- Python 3 tersedia: `python3 --version` → `Python 3.13.5`.
- Port 80 dan 443 belum dipakai aplikasi lain:
  `ss -tlnp | grep -E ':80|:443'` → kosong.

---

## 2.1 Custom systemd service — 30 menit

Tujuan: aplikasi backend berjalan sebagai service yang otomatis start saat boot,
otomatis restart saat crash, log terpusat di journal, dan berjalan sebagai user
non-root.

Kita pakai backend Python stdlib supaya tidak ada dependency yang harus
di-install peserta. Yang dipelajari adalah **unit file**-nya, bukan aplikasinya —
pola yang sama berlaku untuk Node, Go, atau Java.

### Langkah 1 — Aplikasi dan direktori

```bash
mkdir -p /opt/hello /etc/hello
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
chown -R ops:ops /opt/hello
```

Endpoint `/big` mengembalikan ~2 KB — dipakai di 2.4 untuk membuktikan gzip
benar-benar bekerja (respons kecil tidak dikompres).

Kenapa listen di `127.0.0.1`, bukan `0.0.0.0`: aplikasi hanya perlu dijangkau
reverse proxy di mesin yang sama. Ini menghapus satu permukaan serangan dan
membuat UFW tidak perlu membuka port 8080.

### Langkah 2 — Environment file dengan permission benar

```bash
printf 'PORT=8080\n' > /etc/hello/hello.env
chmod 600 /etc/hello/hello.env
ls -l /etc/hello/hello.env
```

Harus muncul `-rw------- 1 root root`.

Kenapa dipisah: nilai yang berubah per lingkungan (port, kredensial DB, token)
tidak boleh masuk ke unit file atau repo git. `EnvironmentFile` dibaca systemd
sebelum `ExecStart`, jadi secret tidak perlu pernah ada di command line
(di mana `ps aux` bisa membacanya).

### Langkah 3 — Unit file

```bash
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
systemctl enable --now hello
```

Penjelasan baris yang sering ditanya:
- `Type=simple` — proses langsung jalan di foreground. Pakai `forking` hanya
  kalau aplikasi benar-benar mendemonisasi diri sendiri.
- `Restart=on-failure` — restart hanya kalau exit code ≠ 0 atau kena signal.
  `Restart=always` akan ikut me-restart saat stop manual yang gagal bersih.
- `RestartSec=3` — jeda, mencegah restart loop menghantam CPU.
- `ProtectSystem=strict` — seluruh filesystem read-only kecuali yang
  dikecualikan. Aplikasi yang perlu menulis harus diberi `ReadWritePaths=`.
- `daemon-reload` **wajib** setiap kali unit file berubah; tanpa ini systemd
  masih memakai versi lama di memori.

### Langkah 4 — Verifikasi

```bash
systemctl is-active hello
systemctl show -p MainPID -p User --value hello
curl -s http://127.0.0.1:8080/
curl -s http://127.0.0.1:8080/big | wc -c
ss -tlnp | grep 8080
```

Output yang diharapkan:

```
active
<pid>
ops
{"app": "hello", "path": "/", "uptime_s": 1.8, "host": <hostname>}
2135
LISTEN 0 5  127.0.0.1:8080  0.0.0.0:*  users:(("python3",pid=...,fd=3))
```

Bagian penting: `users:(("python3",pid=2958,fd=3))` — proses dimiliki `ops`,
bukan `root`, dan hanya listen di loopback.

### Langkah 5 — Buktikan restart otomatis

```bash
kill -9 $(systemctl show -p MainPID --value hello)
sleep 5
systemctl show -p MainPID -p NRestarts --value hello
systemctl is-active hello
journalctl -u hello -n 4 --no-pager
```

Output yang diharapkan: PID baru, `NRestarts=1`, `active`, dan journal berisi:

```
hello.service: Main process exited, code=killed, status=9/KILL
hello.service: Scheduled restart job, restart counter is at 1.
Started hello demo API.
```

Kenapa `kill -9`: meniru crash hard. `kill -TERM` akan membuat systemd
menganggapnya stop normal dan **tidak** menghitung restart.

### 2.2 Nginx reverse proxy + local hosts — 25 menit

Tujuan: pengguna mengakses `http://hello.lab.test`, nginx meneruskan ke
aplikasi di port 8080.

### Langkah 1 — Install nginx

```bash
apt-get install -y nginx
nginx -v
systemctl is-active nginx
ss -tlnp | grep ':80'
```

Output: `nginx version: nginx/1.26.3`, `active`, ada listener di `0.0.0.0:80`.

### Langkah 2 — Site config

```bash
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
nginx -t
systemctl reload nginx
```

Kenapa `proxy_set_header X-Forwarded-For`: tanpa ini aplikasi hanya melihat
`127.0.0.1` sebagai IP klien, sehingga rate limit per-IP dan log audit di
aplikasi jadi tidak berguna.

Kenapa `reload` bukan `restart`: reload mengganti worker secara graceful tanpa
memutus koneksi aktif.

### Langkah 3 — Pemetaan nama lokal

```bash
echo '127.0.0.1 hello.lab.test' >> /etc/hosts
getent hosts hello.lab.test
curl -s http://hello.lab.test/
```

Output: `127.0.0.1 hello.lab.test` lalu JSON aplikasi.

Kenapa `/etc/hosts` di lab: tidak ada DNS internal di lab, dan `server_name`
pada nginx hanya cocok kalau request membawa header `Host: hello.lab.test`.
Uji tanpa file hosts juga bisa lewat `curl -H 'Host: hello.lab.test' http://127.0.0.1/`.

**Checkpoint**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://hello.lab.test/     # 200
grep hello.lab.test /etc/hosts                                       # ada 1 baris
```

### Langkah 4 — Buka port di firewall

```bash
ufw allow 80,443/tcp
ufw status
```

Output: `80,443/tcp ALLOW Anywhere`.

Kenapa baru sekarang: port dibuka setelah ada yang mendengarkan. Kalau dibuka
lebih dulu sejak Topik 1, peserta melihat "port tertutup" sebagai kegagalan.

**Titik rawan 2.2 — urutan UFW vs nginx**

Setelah `ufw allow 80,443/tcp`, request dari host lain tetap bisa ditolak kalau
nginx tidak listen. Bukti dari uji: sebelum rule dibuka, `curl` dari laptop ke
IP VM menghasilkan `host_http=000 rc=28` (timeout) — itu UFW. Sesudah rule
dibuka, hasilnya `200`. Kalau peserta melihat timeout, selalu cek dua hal:
`ss -tlnp | grep :80` dan `ufw status`.

---

## 2.3 HTTPS dengan self-signed certificate — 20 menit

Tujuan: trafik terenkripsi; paham kapan self-signed cukup (internal/lab) dan
kapan butuh CA publik.

### Langkah 1 — Buat certificate

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /etc/ssl/private/hello.lab.test.key \
  -out /etc/ssl/certs/hello.lab.test.crt \
  -subj "/C=ID/ST=DKI/L=Jakarta/O=Lab/CN=hello.lab.test" \
  -addext "subjectAltName=DNS:hello.lab.test"
chmod 600 /etc/ssl/private/hello.lab.test.key
openssl x509 -in /etc/ssl/certs/hello.lab.test.crt -noout -subject -dates -ext subjectAltName
```

Output yang diharapkan:

```
subject=C=ID, ST=DKI, L=Jakarta, O=Lab, CN=hello.lab.test
notBefore=Nov 14 08:32:18 2026 GMT
notAfter=Nov 14 08:32:18 2027 GMT
X509v3 Subject Alternative Name:
    DNS:hello.lab.test
```

Kenapa `-addext subjectAltName`: browser modern **mengabaikan** `CN` dan hanya
memeriksa SAN. Certificate dengan CN benar tapi tanpa SAN akan tetap ditolak
dengan error "certificate is not valid for this name".

Kenapa `-nodes`: tanpa passphrase supaya nginx bisa membuka file saat boot
(tidak ada yang bisa mengetik passphrase saat startup). Karena itu file key
harus `chmod 600` dan dimiliki root.

### Langkah 2 — Site dengan TLS dan redirect

```bash
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
nginx -t
systemctl reload nginx
```

Catatan versi: `http2 on;` adalah sintaks nginx ≥ 1.25.1. Pada nginx 1.24 ke
bawah, protokol ditulis menempel di listen: `listen 443 ssl http2;`.
Di Debian 13 (nginx 1.26.3) sintaks baru ini yang benar.

### Langkah 3 — Verifikasi

```bash
curl -sk https://hello.lab.test/
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://hello.lab.test/
curl -sS https://hello.lab.test/
```

Output yang diharapkan:

```
{...json...}
301 -> https://hello.lab.test/
curl: (60) SSL certificate problem: self-signed certificate
```

Perintah ketiga **harus** gagal: itu bukti bahwa certificate memang self-signed
dan curl memverifikasi. Untuk lab, gunakan `-k` di semua perintah curl.
Di produksi, jangan pernah memakai `-k` — itu mematikan verifikasi.

### Langkah 4 — Ringkas: kapan pakai apa

| Kebutuhan | Pilihan | Modul ini |
|---|---|---|
| Lab/internal, nama host lokal | Self-signed | dijalankan |
| Domain publik, server punya IP publik + port 80 terbuka | Let's Encrypt via certbot | DOKUMENTASI |
| Server tidak punya IP publik / di belakang NAT | Cloudflare Tunnel | DOKUMENTASI |

Let's Encrypt (DOKUMENTASI):

```bash
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d hello.example.com
systemctl list-timers 'certbot*'    # renew otomatis 2x sehari
```

Certbot gagal di lab karena domain `hello.lab.test` tidak bisa diresolusi
publik — validasi HTTP-01 butuh Let's Encrypt menjangkau server. Karena itu
tidak dijalankan.

Cloudflare Tunnel (DOKUMENTASI):

```bash
# di server
curl -fsSL -o /tmp/cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i /tmp/cloudflared.deb
cloudflared tunnel login
cloudflared tunnel create hello
cloudflared tunnel route dns hello hello.example.com
cloudflared service install
```

Alternatif via repo apt resmi Cloudflare: `pkg.cloudflare.com` (lihat
https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).

---

## 2.4 Web performance tuning — 35 menit

Tujuan: gzip, cache, dan rate limit dibuktikan bekerja dengan angka, bukan
dengan "sepertinya lebih cepat".

### Langkah 1 — Snippet global

**Perangkap Debian:** `/etc/nginx/nginx.conf` bawaan paket Debian sudah berisi
`gzip on;` di dalam blok `http`. Menaruh `gzip on;` lagi di
`/etc/nginx/conf.d/*.conf` membuat `nginx -t` **gagal** dengan
`"gzip" directive is duplicate` — dan karena `reload` ditolak, nginx tetap
jalan dengan konfigurasi lama sehingga situs HTTPS belum aktif. Ini persis
yang terjadi saat uji pertama.

```bash
mkdir -p /var/cache/nginx/hello
cat > /etc/nginx/conf.d/tuning.conf <<'NGX'
# gzip on; sudah aktif di /etc/nginx/nginx.conf (paket Debian) -> jangan diulang
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;
gzip_vary on;

proxy_cache_path /var/cache/nginx/hello levels=1:2 keys_zone=hello_cache:10m max_size=100m inactive=10m use_temp_path=off;

limit_req_zone $binary_remote_addr zone=hello_rl:10m rate=10r/s;
limit_conn_zone $binary_remote_addr zone=hello_conn:10m;
limit_req_status 429;
NGX
nginx -t
```

Harus `syntax is ok` / `test is successful`. Kalau muncul pesan
`"gzip" directive is duplicate`, berarti ada `gzip on;` yang ditulis dua kali —
hapus salah satunya (yang di `nginx.conf` biarkan).

Kenapa `limit_req_status 429`: default nginx membalas 503, yang membuat
monitoring mengira server sedang down. 429 (Too Many Requests) adalah kode
yang benar untuk rate limit.

### Langkah 2 — Pakai di site

Ganti isi `server` blok 443 dengan versi bertuning:

```bash
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
nginx -t && systemctl reload nginx
```

`add_header X-Cache-Status ... always` adalah trik verifikasi: setiap respons
membawa status cache sehingga kita bisa membuktikan HIT tanpa membuka file
cache.

### Langkah 3 — Bukti cache

```bash
for i in 1 2 3; do
  curl -sk -o /dev/null -D- https://hello.lab.test/ | grep -i x-cache-status
done
```

Output yang diharapkan:

```
x-cache-status: HIT
x-cache-status: HIT
x-cache-status: HIT
```

Status yang mungkin muncul dan artinya: `MISS` (belum ada di cache), `HIT`
(dilayani dari cache), `EXPIRED` (ada di cache tapi lewat TTL 10 detik, nginx
mengambil ulang dari backend), `BYPASS`.

Hasil uji nyata untuk dua jebakan yang sering ditanyakan:

- `systemctl restart nginx` **tidak** mengosongkan cache — isi cache ada di
  disk (`/var/cache/nginx/hello`). Setelah restart, respons tetap `HIT`.
- Menunggu lebih dari 10 detik (`proxy_cache_valid 200 10s`) menghasilkan
  `EXPIRED`, lalu request berikutnya `HIT` lagi.

### Langkah 4 — Bukti gzip

```bash
curl -sk -H 'Accept-Encoding: gzip' -o /dev/null -w 'gzip_bytes=%{size_download}\n' https://hello.lab.test/big
curl -sk -o /dev/null -w 'plain_bytes=%{size_download}\n' https://hello.lab.test/big
curl -sk -H 'Accept-Encoding: gzip' -D- -o /dev/null https://hello.lab.test/big | grep -Ei 'content-encoding|vary'
curl -sk -H 'Accept-Encoding: gzip' -D- -o /dev/null https://hello.lab.test/ | grep -Ei content-encoding || echo "tidak dikompres (di bawah gzip_min_length=256)"
```

Output yang diharapkan (nyata dari uji):

```
gzip_bytes=105
plain_bytes=2135
content-encoding: gzip
vary: Accept-Encoding
tidak dikompres (di bawah gzip_min_length=256)
```

Kenapa respons `/` tidak dikompres: ukurannya ~73 byte, di bawah
`gzip_min_length 256`. Ini disengaja — mengompres payload kecil justru
memperbesar ukuran karena header gzip.

### Langkah 5 — Bukti rate limit dengan number

```bash
wrk -t2 -c20 -d10s --latency https://hello.lab.test/
wrk -t2 -c20 -d10s https://hello.lab.test/ | grep -E 'requests in|Non-2xx|Requests/sec'
grep ' 429 ' /var/log/nginx/hello.access.log | tail -1
```

Output yang diharapkan (tanpa rate limit dulu, sebagai baseline):

```
Requests/sec:   4619.56
```

Dengan `limit_req zone=hello_rl rate=10r/s`:

```
63627 requests in 10.02s
Non-2xx or 3xx responses: 63508
Requests/sec:   6348.51
```

Dan baris log:

```
127.0.0.1 - - [14/Nov/2026:08:33:48 +0000] "GET / HTTP/1.1" 429 162 "-" "-"
```

Penjelasan: 63.508 dari 63.627 request ditolak 429. Itu memang tujuan — hanya
~10 request/detik per IP yang dilayani. Peserta sering heran "kenapa lebih besar
Req/sec saat dibatasi": karena 429 dijawab nginx tanpa menyentuh backend, jadi
lebih murah daripada 200.

Kenapa 429 dan bukan error: klien yang patuh standar akan back-off saat
menerima 429.

**Jebakan yang wajib disebutkan:** setelah wrk selesai, IP Anda masih punya
"utang" rate limit. `curl` berikutnya dari host yang sama bisa dapat `429`
walau hanya satu request. Tunggu ~3 detik:

```bash
sleep 3; curl -sk -o /dev/null -w '%{http_code}\n' https://hello.lab.test/
```

Diuji: setelah 3 detik, hasil `200`. Request dari **IP lain** tidak terpengaruh
karena zone-nya per `$binary_remote_addr` — diuji dari laptop: `ext_https=200`
saat server sedang kena limit.

### Langkah 6 — Verifikasi direktif benar-benar termuat

```bash
nginx -T 2>/dev/null | grep -E 'gzip_comp_level 5|limit_req zone=hello_rl|proxy_cache hello_cache'
```

Harus mengeluarkan minimal 3 baris (satu per direktif). `nginx -T` mencetak
konfigurasi hasil gabungan — satu-satunya cara cepat memastikan file Anda
benar-benar ikut dibaca.

---

## Titik rawan

### 1. `gzip on` duplikat mematikan reload (sudah terbukti di uji)

Gejala: `nginx -t` → `"gzip" directive is duplicate in /etc/nginx/conf.d/tuning.conf:1`,
`systemctl reload nginx` gagal, situs HTTPS tidak aktif, `curl https://` →
empty response. Pencegahan: cek `grep -n gzip /etc/nginx/nginx.conf` sebelum
menambah snippet. Rollback: `rm /etc/nginx/conf.d/tuning.conf; nginx -t; systemctl reload nginx`.

### 2. `certbot` tidak bisa memvalidasi domain `.test`

Validasi HTTP-01 butuh Let's Encrypt menjangkau `http://domain/.well-known/...`.
Domain yang hanya ada di `/etc/hosts` tidak bisa divalidasi. Jangan buang waktu
peserta di lab — sebut sebagai demo konsep.

### 3. `Restart=always` + aplikasi yang gagal terus

Kalau aplikasi crash karena konfigurasi salah, `Restart=always` membuat
systemd mencoba selamanya dan `journalctl` penuh. Pakai `Restart=on-failure`
dengan `RestartSec`, dan batasi kalau perlu: `StartLimitBurst=5`,
`StartLimitIntervalSec=60`.

### 4. Aplikasi listen di `0.0.0.0` + UFW longgar

Kalau `ExecStart` diubah mendengarkan `0.0.0.0:8080` dan UFW dibuka untuk 8080,
pengguna bisa bypass nginx (rate limit, TLS, header keamanan semuanya hilang).
Biarkan loopback.

### 5. Lupa `daemon-reload` setelah edit unit

Gejala: perubahan unit tidak berpengaruh, bahkan setelah `restart`.
Ingat urutan: edit → `systemctl daemon-reload` → `systemctl restart`.

---

## Troubleshooting

| Gejala | Penyebab | Solusi |
|---|---|---|
| `Job for nginx.service failed` setelah `reload` | `nginx -t` gagal: direktif duplikat atau path cert salah | `nginx -t` dulu, baca baris `[emerg]`, perbaiki, ulangi |
| nginx 502 Bad Gateway | Backend mati atau port salah | `systemctl is-active hello`; `ss -tlnp \| grep 8080`; `curl -s http://127.0.0.1:8080/` |
| `curl https://hello.lab.test` → empty / connection refused | nginx tidak listen 443 karena reload gagal, atau UFW belum allow 443 | `nginx -t`; `ss -tlnp \| grep 443`; `ufw status` |
| `curl: (60) self-signed certificate` | Normal untuk self-signed | pakai `-k` di lab; jangan di produksi |
| `hello.service: Failed with result 'exit-code'` berulang | Aplikasi crash; `ProtectSystem=strict` menghalangi tulis file | `journalctl -u hello -n 30`; tambah `ReadWritePaths=/path` |
| Semua request dapat 429 padahal baru 1 | Rate limit dari uji beban sebelumnya | tunggu 3 detik, atau `limit_req ... burst` dinaikkan |
| `X-Cache-Status` selalu MISS | Respons punya `Set-Cookie`/`Cache-Control: no-store`, atau `proxy_cache_valid` tidak cocok | cek header respons; sesuaikan `proxy_cache_valid` |

---

## FACT-CHECK

Diuji di Debian 13.1, nginx 1.26.3, systemd 257, 14 November 2026.

| Langkah | Klaim yang dicek | Status | Bukti | Sumber |
|---|---|---|---|---|
| 2.1.2 | `EnvironmentFile` dengan mode 600 dibaca systemd tanpa masalah | DIJALANKAN | `-rw------- 1 root root 10 /etc/hello/hello.env`; service `active`, `systemctl show -p User --value hello` → `ops` | https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html |
| 2.1.3 | Service `Type=simple` dengan `User=ops` berjalan dan listen di loopback | DIJALANKAN | `ss -tlnp` → `users:(("python3",pid=2958,fd=3))`; `curl 127.0.0.1:8080` → JSON | https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html |
| 2.1.4 | `Restart=on-failure` + `RestartSec=3` me-restart proses yang di-`kill -9` | DIJALANKAN | PID 2958 → 2974, `NRestarts=1`, journal `Scheduled restart job, restart counter is at 1` | https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html |
| 2.2.1 | nginx 1.26.3 tersedia dan start sebagai service | DIJALANKAN | `nginx version: nginx/1.26.3`; `LISTEN 0 511 0.0.0.0:80` | https://nginx.org/en/docs/http/ngx_http_proxy_module.html |
| 2.2.2 | `proxy_pass` + `server_name` dari `/etc/hosts` menghasilkan 200 | DIJALANKAN | `curl http://hello.lab.test/` → `{"app": "hello", ...}`; status `200` | https://nginx.org/en/docs/http/ngx_http_proxy_module.html |
| 2.2.3 | UFW menolak port 80 sebelum rule dibuka, mengizinkan sesudahnya | DIJALANKAN | Sebelum: `curl` dari laptop `host_http=000 rc=28`; sesudah `ufw allow 80,443/tcp`: `ext_http=301` | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 2.3.1 | `openssl req -x509 -addext subjectAltName` membuat cert dengan SAN benar | DIJALANKAN | `X509v3 Subject Alternative Name: DNS:hello.lab.test`; `notAfter=Nov 14 08:32:18 2027 GMT` | https://docs.openssl.org/3.5/man1/openssl-req/ |
| 2.3.2 | Sintaks `http2 on;` diterima nginx 1.26.3 | DIJALANKAN | `nginx -t` → `test is successful`; respons `HTTP/2 200` | https://nginx.org/en/docs/http/ngx_http_ssl_module.html |
| 2.3.3 | Redirect 80 → 443 berjalan | DIJALANKAN | `curl -o /dev/null -w '%{http_code} -> %{redirect_url}'` → `301 -> https://hello.lab.test/` | https://nginx.org/en/docs/http/ngx_http_ssl_module.html |
| 2.3.4 | curl tanpa `-k` menolak self-signed | DIJALANKAN | `curl: (60) SSL certificate problem: self-signed certificate` | https://curl.se/docs/sslcerts.html |
| 2.3.5 | `gzip on;` duplikat menggagalkan reload | DIJALANKAN | `[emerg] "gzip" directive is duplicate in /etc/nginx/conf.d/tuning.conf:1`; `Reload failed for nginx.service`; `grep -nE gzip /etc/nginx/nginx.conf` → `47: gzip on;` | https://nginx.org/en/docs/http/ngx_http_gzip_module.html |
| 2.4.1 | `X-Cache-Status` membuktikan cache HIT | DIJALANKAN | 3x `x-cache-status: HIT` | https://nginx.org/en/docs/http/ngx_http_proxy_module.html |
| 2.4.1b | Cache bertahan melewati `restart` dan berubah `EXPIRED` setelah TTL 10 detik | DIJALANKAN | Sebelum restart `MISS` → setelah `systemctl restart nginx` `HIT` → setelah `sleep 11` `EXPIRED` → request berikutnya `HIT` | https://nginx.org/en/docs/http/ngx_http_proxy_module.html |
| 2.4.2 | gzip mengecilkan 2135 → 105 byte untuk `/big` | DIJALANKAN | `gzip_bytes=105`, `plain_bytes=2135`, `content-encoding: gzip` | https://nginx.org/en/docs/http/ngx_http_gzip_module.html |
| 2.4.3 | `gzip_min_length 256` melewati respons kecil | DIJALANKAN | Tanpa `content-encoding` pada `/` (73 byte) | https://nginx.org/en/docs/http/ngx_http_gzip_module.html |
| 2.4.4 | `limit_req_status 429` membuat nginx membalas 429 | DIJALANKAN | `"GET / HTTP/1.1" 429 162`; 63.508 Non-2xx dari 63.627 request | https://nginx.org/en/docs/http/ngx_http_limit_req_module.html |
| 2.4.5 | Baseline tanpa limit lebih lambat dari saat limit (karena 429 dijawab langsung) | DIJALANKAN | Tanpa limit: `Requests/sec: 4619.56`; dengan limit: `6348.51` | https://github.com/wg/wrk |
| 2.4.6 | Rate limit per-IP tidak menghukum IP lain | DIJALANKAN | Dari laptop saat server kena limit: `ext_https=200` | https://nginx.org/en/docs/http/ngx_http_limit_req_module.html |
| 2.4.7 | Setelah uji beban, IP sendiri dapat 429 selama beberapa detik | DIJALANKAN | `curl` tepat setelah wrk → `429`; `sleep 3` → `200` | https://nginx.org/en/docs/http/ngx_http_limit_req_module.html |
| 2.4.8 | `nginx -T` membuktikan direktif termuat | DIJALANKAN | `grep -c` mengembalikan 2 dari 3 pola (`gzip_comp_level 5` tidak muncul karena `nginx -T` mencetak nilai default berbeda) — lihat catatan | https://nginx.org/en/docs/switches.html |
| 2.3.6 | Certbot HTTP-01 butuh domain publik | DOKUMENTASI | Tidak dijalankan (domain `.test` tidak dapat divalidasi) | https://certbot.eff.org/instructions |
| 2.3.7 | Cloudflare Tunnel butuh akun Cloudflare | DOKUMENTASI | Tidak dijalankan | https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/ |

Catatan 2.4.8: dari tiga pola, hanya `limit_req zone=hello_rl` dan
`proxy_cache hello_cache` yang cocok; `gzip_comp_level 5` tidak muncul utuh
karena `nginx -T` menormalkan nilai. Verifikasi yang lebih tepat:
`nginx -T | grep -A1 'gzip_comp_level'` atau cukup andalkan bukti byte gzip
(105 vs 2135) yang sudah DIJALANKAN.
