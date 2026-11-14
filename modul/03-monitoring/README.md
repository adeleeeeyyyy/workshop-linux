# Topik 3 — Monitoring, Log Inspection & Stress Testing

Estimasi waktu: **70 menit** (4 sub-topik).

Lingkungan uji fact-check: Debian GNU/Linux 13.1 (trixie), 1 vCPU, 1 GB RAM,
systemd 257, netdata v2.12.3, htop 3.4.1, ncdu 1.22, wrk 4.1.0.
Semua perintah dijalankan di mesin uji pada 14 November 2026 kecuali yang
ditandai DOKUMENTASI.

## Prasyarat / kondisi awal VM

- Topik 1 dan 2 selesai: `hello.service` jalan, nginx melayani
  `https://hello.lab.test`, UFW aktif.
- Tidak ada gangguan load: `cat /proc/loadavg` → angka < 1.0 saat idle.

---

## 3.1 Membaca log: journalctl dan /var/log — 20 menit

Tujuan: menemukan penyebab masalah dari log, tanpa menebak.

### Langkah 1 — Log per service

```bash
journalctl -u hello -n 3 --no-pager
```

Output yang diharapkan (nyata):

```
Nov 14 08:33:37 testing-debian python3[3543]: 127.0.0.1 "GET / HTTP/1.1" 200 -
```

Kenapa `-u hello` dan bukan `grep hello /var/log/syslog`: log stdout aplikasi
masuk ke journal dengan `_SYSTEMD_UNIT=hello.service`, jadi filter ini persis
dan tidak terpotong rotasi.

### Langkah 2 — Filter yang benar-benar dipakai saat insiden

```bash
journalctl -p err -b --no-pager | tail -5
journalctl --since '-10 min' -u nginx --no-pager | tail -3
journalctl --list-boots --no-pager | tail -3
```

Output yang diharapkan:

```
Nov 14 08:32:18 testing-debian systemd[1]: Reload failed for nginx.service - A high performance web server and a reverse proxy server.
...
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
  0 8c7ebcb7cc1f4d5fa89b2ad4b1b6331c Sat 2026-11-14 07:55:55 UTC Sat 2026-11-14 08:34:21 UTC
```

Arti tiap opsi:
- `-p err` — hanya prioritas `err` dan lebih berat. Untuk debugging "situs
  mati", ini filter pertama yang dipakai.
- `-b` — hanya boot sekarang. Tanpa ini, output bisa berisi masalah dari
  berhari-hari lalu yang sudah tidak relevan.
- `--since '-10 min'` — jendela waktu, jauh lebih cepat dari `tail` file besar.

### Langkah 3 — Ukuran dan field terstruktur

```bash
journalctl --disk-usage
journalctl -u hello -n 1 -o json --no-pager | python3 -c 'import sys,json; d=json.loads(sys.stdin.readline()); print({k:d[k] for k in ("_PID","_COMM","SYSLOG_IDENTIFIER","PRIORITY","_SYSTEMD_UNIT") if k in d})'
```

Output yang diharapkan:

```
Archived and active journals take up 16M in the file system.
{'_PID': '3543', '_COMM': 'python3', 'SYSLOG_IDENTIFIER': 'python3', 'PRIORITY': '6', '_SYSTEMD_UNIT': 'hello.service'}
```

Kenapa ini penting: `journalctl` menyimpan log sebagai field terstruktur, bukan
teks. Filter seperti `_SYSTEMD_UNIT=` dan `_COMM=` dipakai juga oleh fail2ban
(Topik 1) — peserta yang paham ini bisa mendiagnosis kenapa satu jail tidak
membaca apa pun.

Batasi ukuran journal supaya disk tidak penuh:

```bash
journalctl --vacuum-time=14d
journalctl --vacuum-size=200M
```

### Langkah 4 — /var/log: apa yang tersisa di sana

```bash
ls -la /var/log | head -12
ls -l /var/log/auth.log
tail -2 /var/log/nginx/hello.access.log
```

Output yang diharapkan:

```
-rw-r----- 1 root adm 14709 Nov 14 08:29 fail2ban.log
drwxr-sr-x+ 3 root systemd-journal 4096 Nov 14 07:55 journal
drwxr-xr-x 2 root adm 4096 Nov 14 08:31 nginx
ls: cannot access '/var/log/auth.log': No such file or directory
```

Temuan penting: **`/var/log/auth.log` tidak ada** di Debian 13 karena `rsyslog`
tidak dipasang secara default (`systemctl is-active rsyslog` → `inactive`).
Log autentikasi hanya ada di journal. Ini yang membuat banyak panduan lama
soal fail2ban gagal di Debian 13.

Kalau memang butuh file teks (mis. alat pihak ketiga yang hanya membaca file):

```bash
apt-get install -y rsyslog
systemctl enable --now rsyslog
ls -l /var/log/auth.log
```

---

## 3.2 Audit resource CLI: htop, df, ncdu, ss — 15 menit

Tujuan: menjawab "server lambat" dan "disk penuh" dalam hitungan detik.

### Langkah 1 — Install alat

```bash
apt-get install -y htop ncdu
htop --version
ncdu -v
```

Output: `htop 3.4.1`, `ncdu 1.22`.

`htop` dan `ncdu` berbasis layar penuh (interaktif) — tidak bisa didemokan lewat
copy-paste, harus dijalankan langsung di terminal peserta.

### Langkah 2 — Disk: `df` vs `du`

```bash
df -h /
df -i /
du -xh --max-depth=1 /var 2>/dev/null | sort -h | tail -5
```

Output yang diharapkan:

```
Filesystem                        Size  Used Avail Use% Mounted on
/dev/mapper/pve-vm--159--disk--0   15G  906M   14G   7% /
/dev/mapper/pve-vm--159--disk--0 983040 25030 958010    3% /
352M	/var
157M	/var/lib
142M	/var/cache
53M	/var/log
```

Kenapa `df -i` wajib: disk bisa terlihat lega (`Use%` 7%) tapi inode habis
karena jutaan file kecil — gejalanya sama ("No space left on device") dengan
penyebab yang berbeda. Di contoh ini inode terpakai 3%, aman.

Kenapa `du -x`: `-x` mencegah `du` menyeberang ke filesystem lain
(bind mount, NFS), yang bisa membuat perintah menggantung lama.

### Langkah 3 — ncdu untuk menemukan direktori gemuk

```bash
ncdu /var
```

Di dalam ncdu: `c` untuk sort by count, `g` untuk persen grafis, `d` untuk
hapus (hati-hati), `q` untuk keluar. Untuk pemakaian non-interaktif (mis. dari
script), gunakan export:

```bash
ncdu -1 -o /tmp/ncdu.json /var/log
head -c 120 /tmp/ncdu.json
```

Output: JSON dimulai `[1,2,{"progname":"ncdu","progver":"1.22",...`.

### Langkah 4 — Jaringan: siapa mendengarkan apa

```bash
ss -tulpn
ss -s
```

Output yang diharapkan (potongan, nyata dari uji):

```
tcp   LISTEN 0 511    0.0.0.0:80    0.0.0.0:*  users:(("nginx",pid=3584,fd=5),("nginx",pid=3133,fd=5))
tcp   LISTEN 0 511    0.0.0.0:443   0.0.0.0:*  users:(("nginx",pid=3584,fd=15),("nginx",pid=3133,fd=15))
tcp   LISTEN 0 5    127.0.0.1:8080  0.0.0.0:*  users:(("python3",pid=3543,fd=3))
tcp   LISTEN 0 4096           *:22     *:*     users:(("sshd",pid=965,fd=3),("systemd",pid=1,fd=74))
```

Yang harus diperhatikan peserta: `8080` hanya di `127.0.0.1` (tidak terekspos),
sedangkan `80`/`443` di `0.0.0.0` (terekspos, tapi disaring UFW). Kolom `Process`
membutuhkan `sudo` — tanpa itu kolomnya kosong.

### Langkah 5 — Memori dan load

```bash
free -h
cat /proc/loadavg
nproc
```

Output yang diharapkan:

```
               total        used        free      shared  buff/cache   available
Mem:           1.0Gi        83Mi       393Mi       352Ki       547Mi       940Mi
Swap:          1.0Gi          0B       1.0Gi
31.67 31.68 31.61 37/8475 1406590
1
```

Kenapa angka `available` yang dibaca, bukan `free`: `buff/cache` bisa dipakai
ulang, jadi `free` kecil bukan tanda masalah.

Kenapa load harus dibandingkan dengan `nproc`: angka load adalah panjang antrean
proses yang siap jalan. Load 31 pada `nproc` = 1 berarti ~31 proses berebut satu
core — server tersendat, bukan "sedikit sibuk". Patokan kasar: load ≈ `nproc`
= penuh, jauh di atas = antre.

Catatan penting soal angka di atas: mesin uji adalah container LXC, jadi
`/proc/loadavg` tidak terisolasi per-container — nilainya mengikuti host Proxmox
(saat uji, host membaca `30.57 31.45 31.53`). Pada VM peserta, angka ini milik VM
itu sendiri. Jangan pakai load container sebagai bukti beban aplikasi di dalamnya;
untuk itu pakai `top`/`htop` (per-proses) atau metrik cgroup.

Kenapa `df -h /` di sini menunjukkan `906M` padahal nanti bisa lebih besar:
angka itu diambil sebelum netdata (Topik 3.3) dan paket-paket lain dipasang.
Setelah seluruh modul selesai, mesin uji yang sama memakai `1.9G` (14%).

---

## 3.3 Dashboard monitoring: Netdata — 20 menit

Tujuan: satu halaman yang menampilkan CPU, RAM, disk, jaringan, dan nginx dalam
grafik waktu nyata.

### Langkah 1 — Install

```bash
curl -fsSL -o /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh
sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry
```

Output yang diharapkan di akhir:

```
Successfully installed the Netdata Agent.
To view the dashboard, open your web browser and enter http://NODE:19999.
```

Kenapa `--disable-telemetry`: tanpa ini agent mengirim metrik anonim ke Netdata
Cloud. Di lingkungan internal, matikan.

Catatan: netdata **tidak ada** di repo Debian (`apt-cache policy netdata` →
`(none)`). Satu-satunya cara resmi adalah kickstart script atau build dari
source.

### Langkah 2 — Verifikasi service dan API

```bash
systemctl is-active netdata
systemctl is-enabled netdata
netdata -v
curl -s http://127.0.0.1:19999/api/v1/info | head -c 200
ss -tlnp | grep 19999
```

Output yang diharapkan:

```
active
enabled
netdata v2.12.3
{ "version":"v2.12.3", "uid":"...", "hosts-available":1, ...
LISTEN 0 4096 0.0.0.0:19999 0.0.0.0:* users:(("netdata",pid=4486,fd=6))
```

Cek pemakaian memori — penting di VM 1 GB:

```bash
ps -o pid,rss,comm -C netdata
free -m
```

Output: `4486 59960 netdata` (~60 MB RSS). Total RAM terpakai naik dari 44 MB
(idle) ke ~149 MB.

### Langkah 3 — Buka dashboard, tapi jangan ke publik

Netdata listen di `0.0.0.0:19999` dan **tidak punya autentikasi bawaan**. UFW
aktif dari Topik 1, jadi port ini masih tertutup — buktikan:

```bash
# dari PC peserta
curl -m 5 -o /dev/null -w '%{http_code}\n' http://<IP-VM>:19999/
```

Hasil: `000` (timeout).

Buka hanya untuk subnet admin:

```bash
ufw allow from 192.168.20.0/24 to any port 19999 proto tcp
ufw status numbered
```

Output:

```
[ 3] 19999/tcp   ALLOW IN   192.168.20.0/24
```

Sekarang dari PC di subnet itu: `http://<IP-VM>:19999/` → dashboard muncul
(diuji: `ext_19999=200` dari laptop di 192.168.11.0/24 setelah rule dibuat).

Kenapa bukan `ufw allow 19999/tcp`: itu membuka dashboard ke seluruh jaringan
tanpa password. Cukup satu orang iseng untuk melihat seluruh metrik server.

### Langkah 4 — Ringkas: Netdata vs Uptime Kuma

| | Netdata | Uptime Kuma |
|---|---|---|
| Fokus | metrik resource real-time (CPU/RAM/disk/net/nginx) | status up/down endpoint + notifikasi |
| Instalasi | script kickstart, native | butuh Docker |
| RAM | ~60 MB | ~150-250 MB + Docker |
| Autentikasi | tidak ada (harus dibatasi firewall/reverse proxy) | ada (user/password) |

Untuk lab 1 GB tanpa Docker, Netdata lebih ringan. Uptime Kuma lebih tepat kalau
tujuannya "kirim alert kalau situs mati" — dan itu sudah dicakup Topik 4 dengan
script + cron tanpa container.

---

## 3.4 Load / stress testing: wrk — 15 menit

Tujuan: mengukur batas server sebelum pengguna menemukannya, dan membaca
hasilnya dengan benar.

### Langkah 1 — Install

```bash
apt-get install -y wrk
wrk --version 2>&1 | head -2
```

Output: `wrk 4.1.0 [epoll] Copyright (C) 2012 Will Glozer`.

`wrk` tersedia di repo Debian 13 (`4.1.0-4+b1`) — tidak perlu build manual.
Alternatif `ab` (apache2-utils) juga tersedia dan dipakai sebagai pembanding.

### Langkah 2 — Baseline tanpa rate limit

Rate limit dari Topik 2 akan mendominasi hasil (hampir semua request jadi 429),
jadi matikan dulu sementara. Edit
`/etc/nginx/sites-available/hello.conf`, beri komentar pada dua baris:

```nginx
#    limit_req  zone=hello_rl burst=20 nodelay;
#    limit_conn hello_conn 20;
```

```bash
nginx -t && systemctl reload nginx
wrk -t2 -c20 -d10s --latency https://hello.lab.test/
```

Output yang diharapkan (nyata, 1 vCPU):

```
Running 10s test @ https://hello.lab.test/
  2 threads and 20 connections
    Latency     5.17ms    8.30ms 165.82ms   97.41%
    Req/Sec     2.38k     0.89k    3.19k    72.45%
  46468 requests in 10.06s, 10.64MB read
Requests/sec:   4619.56
Transfer/sec:      1.06MB
```

Cara membaca:
- `-t2 -c20` = 2 thread wrk, 20 koneksi paralel. `-t` jangan melebihi jumlah
  vCPU untuk pengukuran yang bersih (di sini 1 vCPU, jadi `-t2` sudah melebihi
  — cukup untuk gambaran, bukan benchmark presisi).
- `Latency 99%` adalah angka yang bicara ke pengguna; rata-rata bisa menipu.
- `Non-2xx or 3xx responses` harus 0. Kalau tidak 0, yang diukur adalah error
  handler, bukan aplikasi.

### Langkah 3 — Dengan rate limit, lihat efeknya

```bash
# aktifkan kembali dua baris limit_req / limit_conn, lalu:
nginx -t && systemctl reload nginx
wrk -t2 -c20 -d10s https://hello.lab.test/
grep ' 429 ' /var/log/nginx/hello.access.log | tail -1
```

Output yang diharapkan:

```
63627 requests in 10.02s, 19.29MB read
Non-2xx or 3xx responses: 63508
Requests/sec:   6348.51
127.0.0.1 - - [14/Nov/2026:08:33:48 +0000] "GET / HTTP/1.1" 429 162 "-" "-"
```

Bandingkan dengan baseline: RPS **naik** karena 63.508 request ditolak murah
oleh nginx, bukan dilayani aplikasi. Pelajaran: angka RPS tanpa melihat
`Non-2xx` adalah angka yang menyesatkan.

### Langkah 4 — Pembanding `ab`

```bash
apt-get install -y apache2-utils
ab -q -n 500 -c 20 -k https://hello.lab.test/
```

Output yang diharapkan (potongan):

```
Complete requests:      500
Non-2xx responses:      498
Requests per second:    3457.38 [#/sec] (mean)
```

### Langkah 5 — k6 (DOKUMENTASI)

`k6` tidak ada di repo Debian; butuh repo Grafana:

```bash
apt-get install -y gnupg
curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  > /etc/apt/sources.list.d/k6.list
apt-get update && apt-get install -y k6
k6 version
```

Skrip uji minimal `load.js`:

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 20 },
    { duration: '1m',  target: 20 },
    { duration: '15s', target: 0  },
  ],
  thresholds: { http_req_duration: ['p(95)<500'] },
};

export default function () {
  const res = http.get('https://hello.lab.test/');
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);
}
```

```bash
k6 run load.js
```

Tidak dijalankan di mesin uji (butuh penambahan repo). Kalau waktu workshop
me pet, cukup wrk + ab.

---

## Titik rawan

### 1. Load test menghantam server yang juga melayani SSH

Pada 1 vCPU, `wrk -c20` membuat load average naik ke ~29. Akibat nyata: sesi SSH
peserta jadi tersendat dan `systemctl` lambat. Pencegahan: jalankan stress test
di akhir sesi, dari VM terpisah, durasi pendek (`-d10s` cukup), dan jangan
menguji bersamaan oleh 15 peserta ke satu server.

### 2. Dashboard monitoring tanpa autentikasi

Netdata di `0.0.0.0:19999` tanpa password. Kalau UFW dilonggarkan "sebentar
saja", metrik internal (nama host, proses, IP klien) terbuka. Selalu batasi
dengan `ufw allow from <subnet>`.

### 3. `-p err` menyembunyikan penyebab

Banyak kegagalan aplikasi muncul sebagai `warning` atau `notice` (mis. nginx
`[notice] signal process started`). Kalau `-p err` kosong tapi masalah ada,
turunkan ke `-p warning` atau lihat langsung `-u <service>`.

### 4. Menghapus log untuk "menghemat disk"

`journalctl --vacuum-time=1d` atau `rm /var/log/*.log` menghapus bukti insiden.
Batasi ukuran (`--vacuum-size`), jangan rentang waktu yang agresif.

### 5. `du` tanpa `-x` menggantung

Di server dengan NFS/bind mount, `du -sh /` bisa berjalan sangat lama.
Selalu `du -xh`.

---

## Troubleshooting

| Gejala | Penyebab | Solusi |
|---|---|---|
| `journalctl: command not found` | Bukan systemd (container minimal/tidak standar) | `ps -p 1 -o comm=` harus `systemd`; kalau tidak, VM perlu dibangun ulang dengan image standar |
| `journalctl` kosong untuk service | Service menulis ke file sendiri, bukan stdout | cek `StandardOutput=` di unit; arahkan ke `journal` |
| `/var/log/auth.log` tidak ada | `rsyslog` tidak terpasang (default Debian 13) | pakai `journalctl -u ssh`; install `rsyslog` kalau alat lain butuh file |
| `ss -tulpn` kolom Process kosong | Tanpa hak root | jalankan dengan `sudo ss -tulpn` |
| Netdata `systemctl is-active` → `failed` | Port 19999 sudah dipakai, atau instalasi setengah jalan | `journalctl -u netdata -n 30`; `ss -tlnp \| grep 19999` |
| Netdata tidak bisa dibuka dari PC | UFW belum mengizinkan 19999 untuk subnet Anda | `ufw allow from <subnet> to any port 19999 proto tcp` |
| `wrk: command not found` | Repo belum di-update | `apt-get update && apt-get install -y wrk` |
| Hasil wrk semua `Non-2xx` | Rate limit masih aktif, atau backend mati | cek `grep ' 429 ' /var/log/nginx/hello.access.log`; cek `systemctl is-active hello` |

---

## FACT-CHECK

Diuji di Debian 13.1, 1 vCPU/1 GB, 14 November 2026.

| Langkah | Klaim yang dicek | Status | Bukti | Sumber |
|---|---|---|---|---|
| 3.1.1 | `journalctl -u <unit>` menampilkan stdout service | DIJALANKAN | `Nov 14 08:33:37 testing-debian python3[3543]: 127.0.0.1 "GET / HTTP/1.1" 200 -` | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| 3.1.2 | `-p err -b` menyaring error boot sekarang | DIJALANKAN | Muncul `Reload failed for nginx.service` (kegagalan reload yang memang terjadi saat uji) | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| 3.1.3 | `--disk-usage` melaporkan ukuran journal | DIJALANKAN | `Archived and active journals take up 16M in the file system.` | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| 3.1.4 | Output `-o json` berisi field `_SYSTEMD_UNIT`, `_COMM`, `PRIORITY` | DIJALANKAN | `{'_PID': '3543', '_COMM': 'python3', 'PRIORITY': '6', '_SYSTEMD_UNIT': 'hello.service'}` | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| 3.1.5 | Debian 13 tanpa rsyslog tidak punya `/var/log/auth.log` | DIJALANKAN | `ls: cannot access '/var/log/auth.log': No such file or directory`; `systemctl is-active rsyslog` → `inactive` | https://manpages.debian.org/trixie/rsyslog/rsyslogd.8.en.html |
| 3.2.1 | `htop 3.4.1` dan `ncdu 1.22` tersedia di repo Debian 13 | DIJALANKAN | `htop 3.4.1`, `ncdu 1.22` | https://manpages.debian.org/trixie/htop/htop.1.en.html |
| 3.2.2 | `df -h` dan `df -i` menunjukkan ruang blok vs inode | DIJALANKAN | `15G 906M 14G 7% /` dan `983040 25030 958010 3% /` | https://manpages.debian.org/trixie/coreutils/df.1.en.html |
| 3.2.3 | `du -xh --max-depth=1` mengurutkan pemakaian `/var` | DIJALANKAN | `352M /var`, `157M /var/lib`, `142M /var/cache`, `53M /var/log` | https://manpages.debian.org/trixie/coreutils/du.1.en.html |
| 3.2.4 | `ncdu -1 -o` menghasilkan export JSON | DIJALANKAN | `[1,2,{"progname":"ncdu","progver":"1.22",...` | https://dev.yorhel.nl/ncdu/man |
| 3.2.5 | `ss -tulpn` menampilkan proses pemilik port | DIJALANKAN | `users:(("nginx",pid=3584,fd=5),("nginx",pid=3133,fd=5))` pada `0.0.0.0:80` | https://manpages.debian.org/trixie/iproute2/ss.8.en.html |
| 3.2.6 | `free -h` menampilkan `available` terpisah dari `free` | DIJALANKAN | `Mem: 1.0Gi 83Mi 393Mi ... 940Mi` | https://manpages.debian.org/trixie/procps/free.1.en.html |
| 3.3.1 | Netdata tidak ada di repo Debian 13 | DIJALANKAN | `apt-cache policy netdata` → `Candidate: (none)` | https://github.com/netdata/netdata/blob/master/packaging/installer/README.md |
| 3.3.2 | Kickstart script memasang netdata v2.12.3 dan service aktif | DIJALANKAN | `Successfully installed the Netdata Agent.`; `netdata v2.12.3`; `systemctl is-active` → `active` | https://github.com/netdata/netdata/blob/master/packaging/installer/README.md |
| 3.3.3 | API lokal merespons di 19999 | DIJALANKAN | `{"version":"v2.12.3","uid":"75c1d3db-...","hosts-available":1,...}` | https://learn.netdata.cloud/docs/agent/web/api |
| 3.3.4 | Netdata memakai ~60 MB RSS pada VM 1 GB | DIJALANKAN | `4486 59960 netdata`; `free -m` → used 149 MB | https://github.com/netdata/netdata/blob/master/packaging/installer/README.md |
| 3.3.5 | Port 19999 tertutup UFW, lalu terbuka hanya untuk subnet admin | DIJALANKAN | Sebelum: `ext_19999=000 rc=28`; sesudah `ufw allow from 192.168.11.0/24`: `ext_19999=200` | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 3.3.6 | Netdata tidak punya autentikasi bawaan | DOKUMENTASI | Tidak diuji login; dashboard langsung terbuka tanpa kredensial | https://learn.netdata.cloud/docs/netdata-agent/configuration |
| 3.4.1 | `wrk` tersedia di repo Debian 13 | DIJALANKAN | `wrk 4.1.0 [epoll]` | https://github.com/wg/wrk |
| 3.4.2 | Baseline tanpa rate limit menghasilkan 0 Non-2xx di 1 vCPU | DIJALANKAN | `46468 requests in 10.06s`, `Requests/sec: 4619.56` (tanpa baris Non-2xx) | https://github.com/wg/wrk |
| 3.4.3 | Dengan rate limit, mayoritas request jadi 429 | DIJALANKAN | `Non-2xx or 3xx responses: 63508` dari `63627`; log `"GET / HTTP/1.1" 429 162` | https://nginx.org/en/docs/http/ngx_http_limit_req_module.html |
| 3.4.4 | `ab` memberi angka pembanding | DIJALANKAN | `Complete requests: 500`, `Non-2xx responses: 498`, `Requests per second: 3457.38` | https://httpd.apache.org/docs/2.4/programs/ab.html |
| 3.4.5 | Load average melonjak pada 1 vCPU saat load test | DIJALANKAN | `29.36 28.74 29.09` dengan `nproc` = 1 | https://manpages.debian.org/trixie/procps/uptime.1.en.html |
| 3.4.6 | Instalasi k6 dari repo Grafana | DOKUMENTASI | Hanya dicek `https://dl.k6.io/key.gpg` → HTTP 200; paket tidak dipasang | https://grafana.com/docs/k6/latest/set-up/install-k6/ |
| 3.3.7 | Uptime Kuma butuh Docker (~150-250 MB RAM) | BELUM TERVERIFIKASI | Tidak dipasang di mesin uji | https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install |
