# Modul 2: Web, Service & Performance Readiness

Setiap sub-topik berdiri sendiri. Backend contoh disediakan di dalam tiap
sub-topik, jadi tidak ada ketergantungan antar bagian.

Konvensi:
- `<IP-VM>` IP VM. Domain lab selalu `app.local`, ditulis apa adanya.
- Label **[Server]** dijalankan di VM sebagai `root`. Label **[PC Windows]**
  dijalankan di PowerShell Windows 10/11 (padanan Linux atau macOS ada di
  README utama).
- File konfigurasi ditulis sebagai `File: <path>` lalu isinya. Edit sendiri
  dengan `nano <path>`, simpan `Ctrl+O` `Enter`, keluar `Ctrl+X`.
- OS acuan Debian 13.1, nginx 1.26.3, systemd 257.

---

## 2.0 Memetakan app.local di PC peserta

Dipakai oleh 2.2, 2.3, dan 2.4. Lakukan sekali di PC Anda. Domain `app.local`
tidak ada di DNS, jadi PC harus diberi tahu lewat file `hosts`.

**[PC Windows]** buka PowerShell sebagai Administrator (klik kanan menu Start,
`Terminal (Admin)`), lalu:

```powershell
notepad C:\Windows\System32\drivers\etc\hosts
```

File: `C:\Windows\System32\drivers\etc\hosts` (tambahkan di baris paling bawah)

```text
<IP-VM> app.local
```

Simpan. Pastikan nama file tetap `hosts`, bukan `hosts.txt`.

Linux atau macOS: `sudo nano /etc/hosts`, isi baris yang sama.

Verifikasi dari **[PC Windows]**:

```powershell
ipconfig /flushdns
ping app.local          # membalas dari <IP-VM>
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| Notepad bilang tidak bisa menyimpan | PowerShell bukan Administrator | tutup, buka ulang sebagai Administrator |
| File tersimpan sebagai `hosts.txt` | tipe file Notepad `Text Documents` | `Save as`, pilih `All Files`, nama `hosts` |
| `ping` bilang `could not find host` | baris salah ketik atau belum disimpan | buka lagi file hosts, periksa baris |
| `ping` ke IP lama | cache DNS Windows | `ipconfig /flushdns` |

Jebakan:
- Akhiran `.local` dipakai mDNS. Di Windows, file hosts tetap didahulukan, jadi
  aman untuk lab.
- Antivirus atau VPN kantor kadang mengunci file hosts. Matikan sementara kalau
  Notepad menolak menyimpan walau sudah Administrator.

---

## 2.1 Menjalankan aplikasi sebagai systemd service

Hasil: aplikasi jalan otomatis saat boot, restart sendiri saat crash, log masuk
journal, dan berjalan sebagai user non-root.

Paket: `python3`.

```bash
apt-get install -y python3
```

Prasyarat: root, port 8080 kosong (`ss -tlnp | grep 8080` tanpa hasil).

**1. [Server]** user khusus aplikasi dan direktorinya:

```bash
useradd --system --no-create-home --shell /usr/sbin/nologin appsvc
mkdir -p /opt/demo /etc/demo
```

**2.** Aplikasi contoh (Python stdlib, tanpa dependency).

File: `/opt/demo/app.py`

```python
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
```

```bash
chown -R appsvc:appsvc /opt/demo
```

**3.** Nilai yang berubah per lingkungan, tidak masuk unit file.

File: `/etc/demo/demo.env`

```text
PORT=8080
```

```bash
chmod 600 /etc/demo/demo.env
```

**4.** Unit file.

File: `/etc/systemd/system/demo.service`

```ini
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
```

**5.** Aktifkan. `daemon-reload` wajib tiap kali unit file berubah:

```bash
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

## 2.2 Reverse proxy nginx dan domain app.local

Hasil: `http://app.local` dari PC Anda dilayani nginx dan diteruskan ke
aplikasi di port 8080.

Paket: `nginx`, `python3`, `curl`.

```bash
apt-get install -y nginx python3 curl
```

Prasyarat: root, 2.0 selesai (hosts di PC), port 8080 kosong.

**1. [Server]** backend contoh.

```bash
mkdir -p /srv/backend
nano /srv/backend/index.html
```

File: `/srv/backend/index.html`

```text
backend ok
```

Jalankan di sesi SSH kedua dan biarkan terbuka (`Ctrl+C` untuk berhenti):

```bash
python3 -m http.server 8080 --bind 127.0.0.1 --directory /srv/backend
```

Dari sesi pertama, pastikan hidup: `curl -s http://127.0.0.1:8080/`.

**2.** Vhost nginx.

File: `/etc/nginx/sites-available/app.conf`

```nginx
server {
    listen 80;
    server_name app.local;

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
```

```bash
ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
nginx -t
systemctl reload nginx
ufw allow 80/tcp      # kalau UFW terpasang
```

Verifikasi di **[Server]**:

```bash
curl -s -H 'Host: app.local' http://127.0.0.1/   # backend ok
```

Verifikasi dari **[PC Windows]**:

```powershell
curl.exe -s http://app.local/                              # backend ok
curl.exe -s -o NUL -w '%{http_code}' http://<IP-VM>/       # 200
```

Buka juga `http://app.local/` di browser PC: harus tampil `backend ok`.

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `502 Bad Gateway` | backend mati atau port beda | `ss -tlnp \| grep 8080`, cek `proxy_pass` |
| Halaman nginx default muncul | vhost lain menang | `ls -l /etc/nginx/sites-enabled/`, hapus symlink `default` |
| `Job for nginx.service failed` | `nginx -t` gagal | baca baris `[emerg]`, perbaiki, reload lagi |
| Timeout dari PC | UFW menutup port 80 | `ufw allow 80/tcp` |
| Browser tidak menemukan `app.local` | hosts PC belum benar | ulangi 2.0 |
| `curl` di PowerShell mencetak error aneh | `curl` adalah alias `Invoke-WebRequest` | pakai `curl.exe` |

Jebakan:
- `server_name` hanya cocok kalau request membawa header `Host` yang sama. Uji
  di server tanpa hosts bisa pakai `curl -H 'Host: app.local' http://127.0.0.1/`.
- Tanpa `X-Forwarded-For`, aplikasi melihat semua klien sebagai `127.0.0.1`.
  Log audit dan rate limit per IP jadi tidak berguna.
- `systemctl reload nginx` gagal menyisakan worker lama tetap jalan. Situs
  terlihat normal padahal config baru belum aktif. Selalu baca output
  `nginx -t`.

---

## 2.3 HTTPS dengan sertifikat self-signed

Hasil: `https://app.local` dilayani HTTPS, dan port 80 dialihkan ke 443.
Sertifikat dibuat sendiri, jadi browser akan memberi peringatan. Itu normal
untuk lab.

Paket: `nginx`, `openssl`, `curl`.

```bash
apt-get install -y nginx openssl curl
```

Prasyarat: root, 2.0 selesai (hosts di PC), port 80 dan 443 terbuka di
firewall (`ufw allow 80/tcp; ufw allow 443/tcp` kalau UFW terpasang).

**1. [Server]** buat sertifikat dan key. SAN wajib ada supaya browser modern
menerima nama `app.local`:

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /etc/ssl/private/app.local.key \
  -out /etc/ssl/certs/app.local.crt \
  -subj "/CN=app.local" \
  -addext "subjectAltName=DNS:app.local"
chmod 600 /etc/ssl/private/app.local.key
```

**2.** Isi situs statis dan bersihkan vhost dari 2.2 supaya tidak bentrok:

```bash
rm -f /etc/nginx/sites-enabled/app.conf
mkdir -p /srv/site
nano /srv/site/index.html
```

File: `/srv/site/index.html`

```text
https ok
```

**3.** Vhost HTTPS.

File: `/etc/nginx/sites-available/tls.conf`

```nginx
server {
    listen 80;
    server_name app.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name app.local;

    ssl_certificate     /etc/ssl/certs/app.local.crt;
    ssl_certificate_key /etc/ssl/private/app.local.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root  /srv/site;
    index index.html;
}
```

```bash
ln -sf /etc/nginx/sites-available/tls.conf /etc/nginx/sites-enabled/tls.conf
nginx -t && systemctl reload nginx
```

`http2 on;` sintaks nginx 1.25.1 ke atas. Di nginx 1.24 ke bawah tulis
`listen 443 ssl http2;`.

Verifikasi di **[Server]**:

```bash
openssl x509 -in /etc/ssl/certs/app.local.crt -noout -subject -ext subjectAltName
curl -sk --resolve app.local:443:127.0.0.1 https://app.local/   # https ok
```

Verifikasi dari **[PC Windows]**:

```powershell
curl.exe -k -s https://app.local/                                    # https ok
curl.exe -s -o NUL -w '%{http_code} %{redirect_url}' http://app.local/   # 301 https://app.local/
curl.exe -s https://app.local/                                       # error 60, sertifikat tidak tepercaya
```

Di browser PC, buka `https://app.local/`. Muncul peringatan sertifikat. Pilih
`Advanced`, lalu `Continue` atau `Proceed`. Halaman `https ok` tampil. Klik
ikon gembok, lihat detail sertifikat, dan cari `app.local` di bagian
`Subject Alternative Name`.

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `curl: (60) schannel: SEC_E_UNTRUSTED_ROOT` | normal untuk self-signed | pakai `-k` di lab |
| `nginx -t` gagal karena `http2` | nginx versi lama | `listen 443 ssl http2;` |
| Browser menolak cert meski `CN` benar | SAN tidak ada | buat ulang dengan `-addext "subjectAltName=DNS:app.local"` |
| `conflicting server name "app.local"` | `app.conf` dari 2.2 masih aktif | `rm /etc/nginx/sites-enabled/app.conf` |
| Browser tidak menemukan `app.local` | hosts PC belum benar | ulangi 2.0 |

Jebakan:
- `-nodes` membuat key tanpa passphrase. Itu syarat nginx bisa start saat boot,
  jadi file key wajib mode 600 dan milik root.
- Jangan pakai `curl -k` di produksi. Itu mematikan verifikasi.
- Redirect 80 ke 443 harus di vhost yang sama. Kalau `default` masih aktif,
  request bisa mendarat di sana.
- Self-signed memberi enkripsi tetapi tidak membuktikan identitas server.
  Karena itu browser memperingatkan.

---

## 2.4 gzip, cache, dan rate limit

Hasil: respons dikompres, konten di-cache, dan request berlebih ditolak 429.

Paket: `nginx`, `python3`, `curl`, `wrk`, `apache2-utils`.

```bash
apt-get install -y nginx python3 curl wrk apache2-utils
```

Prasyarat: root, 2.0 selesai (hosts di PC), port 80 terbuka. Backend contoh
disediakan di bawah.

**1. [Server]** isi situs dan backend contoh:

```bash
rm -f /etc/nginx/sites-enabled/app.conf /etc/nginx/sites-enabled/tls.conf
mkdir -p /srv/site /srv/backend

# file teks 35 KB untuk uji gzip, bawaan Debian
cp /usr/share/common-licenses/GPL-3 /srv/site/big.txt

nano /srv/site/index.html
nano /srv/backend/index.html
```

File: `/srv/site/index.html`

```text
index
```

File: `/srv/backend/index.html`

```text
backend ok
```

Jalankan backend di sesi SSH kedua dan biarkan terbuka:

```bash
python3 -m http.server 8080 --bind 127.0.0.1 --directory /srv/backend
```

**2.** Satu file untuk semua direktif. Dua file yang sama-sama menulis
`gzip_comp_level` membuat `nginx -t` gagal `directive is duplicate`.

File: `/etc/nginx/conf.d/tuning.conf`

```nginx
# gzip on; sudah ada di /etc/nginx/nginx.conf (paket Debian). Jangan diulang
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript;
gzip_vary on;

proxy_cache_path /var/cache/nginx/site levels=1:2 keys_zone=site_cache:10m max_size=50m inactive=10m use_temp_path=off;

limit_req_zone $binary_remote_addr zone=site_rl:10m rate=10r/s;
limit_req_status 429;
```

**3.** Vhost.

File: `/etc/nginx/sites-available/app.conf`

```nginx
server {
    listen 80;
    server_name app.local;

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
```

```bash
ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
nginx -t && systemctl reload nginx
```

Direktori cache dibuat sendiri oleh nginx saat start.

Verifikasi gzip dari **[PC Windows]**. File 35.149 byte menjadi sekitar 12 KB:

```powershell
curl.exe -s -H 'Accept-Encoding: gzip' -o NUL -w 'gzip=%{size_download}\n' http://app.local/big.txt
curl.exe -s -o NUL -w 'plain=%{size_download}\n' http://app.local/big.txt
curl.exe -s -H 'Accept-Encoding: gzip' -D - -o NUL http://app.local/big.txt | Select-String content-encoding
```

Verifikasi cache dari **[PC Windows]**, urutan `MISS`, `HIT`, `HIT`:

```powershell
1..3 | ForEach-Object { curl.exe -s -D - -o NUL http://app.local/cached/ | Select-String x-cache-status }
```

Verifikasi rate limit di **[Server]**. Beban dijalankan dari VM sendiri, lalu
hitung respons 429:

```bash
wrk -t2 -c20 -d5s -H 'Host: app.local' http://127.0.0.1/big.txt | grep -E 'requests in|Non-2xx|Requests/sec'
grep -c ' 429 ' /var/log/nginx/access.log
```

`Non-2xx` dan jumlah 429 harus besar. Limit dihitung per IP, jadi IP PC Anda
tidak ikut terkena. Dari **[PC Windows]** tetap 200:

```powershell
curl.exe -s -o NUL -w '%{http_code}' http://app.local/
```

Kalau ingin merasakan 429 dari PC, jalankan sebelum `wrk` selesai dua jendela
PowerShell yang mengulang perintah di atas dengan cepat. Hasilnya tidak
deterministik, `wrk` di VM tetap bukti utama.

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `"gzip" directive is duplicate` | `gzip on;` ditulis dua kali | hapus salah satu, sisakan yang di `nginx.conf` |
| `gzip_comp_level` duplicate | dua file di `conf.d` menulis direktif sama | gabungkan ke satu file |
| `X-Cache-Status` selalu MISS | respons punya `Set-Cookie` atau `Cache-Control: no-store` | sesuaikan `proxy_cache_valid`, cek header backend |
| `X-Cache-Status` tidak muncul | backend di sesi kedua tidak jalan, atau path bukan `/cached/` | jalankan backend, cek URL |
| Semua request 429 setelah load test | token rate limit habis | tunggu 3 detik, atau naikkan `burst` |
| Respons kecil tidak terkompres | di bawah `gzip_min_length 256` | normal, kompresi justru memperbesar |

Jebakan:
- `limit_req_status` default 503. Monitoring akan membaca itu sebagai server
  down. Pakai 429.
- Rate limit dihitung per IP. Setelah wrk, IP loopback VM masih kena 429 selama
  beberapa detik, sedangkan IP PC Anda tidak terpengaruh.
- `systemctl restart nginx` tidak mengosongkan cache. Isinya di
  `/var/cache/nginx/site`, kedaluwarsa mengikuti `proxy_cache_valid`.
- Kompresi hanya untuk tipe di `gzip_types`. Tambahkan sendiri kalau backend
  mengirim tipe lain.
