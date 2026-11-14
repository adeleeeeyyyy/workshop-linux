# Modul 3: Monitoring, Log Inspection & Stress Testing

Setiap sub-topik berdiri sendiri, tanpa prasyarat dari modul lain.

Total 70 menit untuk keempat sub-topik.

Konvensi:
- `<domain>` nama host contoh `app.lab.test`, `<IP-VM>` IP VM.
- Semua perintah sebagai `root`.
- OS acuan Debian 13.1, systemd 257, 1 vCPU.

---

## 3.1 Membaca log dengan journalctl dan /var/log · 15 menit

Hasil: bisa menemukan penyebab masalah dari log tanpa menebak.

Prasyarat: root, systemd sebagai init (`ps -p 1 -o comm=` menghasilkan `systemd`).

```bash
# log satu service
journalctl -u nginx -n 20 --no-pager

# hanya error, hanya boot sekarang
journalctl -p err -b --no-pager | tail -20

# jendela waktu
journalctl --since '-15 min' --no-pager | tail -30

# daftar boot
journalctl --list-boots --no-pager | tail -5

# ukuran journal
journalctl --disk-usage

# field terstruktur, bukan teks bebas
journalctl -u nginx -n 1 -o json --no-pager | head -c 400
```

Verifikasi:

```bash
journalctl -p err -b --no-pager | wc -l     # ada output, tidak error
ls -la /var/log | head -10                  # ada journal/, nginx/, dpkg.log
```

Batasi ukuran journal agar disk tidak penuh:

```bash
journalctl --vacuum-size=200M
journalctl --vacuum-time=14d
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `journalctl` kosong untuk satu service | aplikasi menulis ke file sendiri, bukan stdout | cek `StandardOutput=` di unit |
| `/var/log/auth.log` tidak ada | Debian 13 tidak memasang `rsyslog` | pakai `journalctl -u ssh` |
| `-p err` tidak menampilkan apa pun padahal ada masalah | banyak kegagalan tercatat sebagai `warning` | turunkan ke `-p warning`, atau lihat `-u <service>` |
| File log butuh alat pihak ketiga | alat itu hanya membaca file teks | `apt-get install -y rsyslog`, lalu cek `/var/log/` |

Jebakan:
- `-p err` menyembunyikan `notice` dan `warning`. Pesan `[notice] signal process
  started` dari nginx hilang di filter itu.
- `rm /var/log/*` atau `--vacuum-time=1d` menghapus bukti insiden. Batasi ukuran,
  bukan rentang waktu yang agresif.
- Log stdout service masuk ke journal dengan field `_SYSTEMD_UNIT`. Filter itu
  yang dipakai fail2ban juga.

---

## 3.2 Audit resource: htop, df, ncdu, ss · 15 menit

Hasil: menjawab "server lambat" dan "disk penuh" dalam hitungan detik.

Prasyarat: root.

```bash
apt-get install -y htop ncdu

htop              # interaktif: q keluar, F6 urutkan, F4 filter
ncdu /var         # interaktif: c urut jumlah, d hapus, q keluar
```

Perintah non-interaktif:

```bash
df -h /            # ruang blok
df -i /            # inode
du -xh --max-depth=1 /var | sort -h | tail -5
free -h
cat /proc/loadavg
ss -tulpn
ss -s
```

Verifikasi:

```bash
df -h / | tail -1                    # ada baris filesystem
ss -tulpn | head -5                  # ada LISTEN, kolom Process terisi
ncdu -1 -o /tmp/ncdu.json /var/log   # menghasilkan JSON
head -c 80 /tmp/ncdu.json
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `No space left on device` padahal `df -h` lega | inode habis | cek `df -i`, cari direktori dengan banyak file kecil |
| Kolom Process di `ss` kosong | tanpa hak root | jalankan `sudo ss -tulpn` |
| `du` menggantung lama | menyeberang ke NFS atau bind mount | pakai `du -xh` |
| `htop` tampil aneh lewat SSH | terminal tidak mendukung warna | `htop -C`, atau pakai `top -b -n1` |

Jebakan:
- `free` kecil bukan tanda masalah. Baca kolom `available`, bukan `free`.
- Load harus dibandingkan dengan `nproc`. Load 31 di mesin 1 core berarti
  antrean panjang.
- Di container, `/proc/loadavg` mengikuti host, bukan container. Untuk beban
  proses sendiri pakai `htop` atau metrik cgroup.

---

## 3.3 Dashboard monitoring dengan Netdata · 20 menit

Hasil: satu halaman berisi grafik CPU, RAM, disk, jaringan, dan nginx.

Prasyarat: root, internet keluar.

```bash
curl -fsSL -o /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh
sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry
```

`--disable-telemetry` mematikan pengiriman metrik ke Netdata Cloud. Paket
`netdata` tidak ada di repo Debian, jadi script ini satu-satunya cara resmi.

Verifikasi:

```bash
systemctl is-active netdata
systemctl is-enabled netdata
netdata -v
curl -s http://127.0.0.1:19999/api/v1/info | head -c 200
ss -tlnp | grep 19999
ps -o pid,rss,comm -C netdata        # RSS sekitar 60 MB
```

Buka dashboard tanpa membuka ke publik (kalau UFW terpasang):

```bash
ufw allow from <subnet-admin> to any port 19999 proto tcp
ufw status numbered
```

Lalu akses `http://<IP-VM>:19999/` dari PC di subnet itu.

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `systemctl is-active` failed | instalasi setengah jalan atau port dipakai | `journalctl -u netdata -n 40`, `ss -tlnp \| grep 19999` |
| Dashboard tidak terbuka dari PC | UFW belum mengizinkan 19999 | `ufw allow from <subnet> to any port 19999 proto tcp` |
| RAM penuh setelah install | VM di bawah 1 GB | tambah RAM, atau turunkan retensi Netdata |

Jebakan:
- Netdata listen di `0.0.0.0:19999` tanpa autentikasi. Jangan
  `ufw allow 19999/tcp`. Batasi per subnet.
- `apt-cache policy netdata` menghasilkan `(none)`. Jangan buang waktu mencari
  paket di repo.
- Netdata memakai sekitar 60 MB RSS di VM 1 GB. Di bawah itu, kurangi retensi
  atau pakai `top` dan `journalctl` saja.

---

## 3.4 Load test dengan wrk dan ab · 20 menit

Hasil: tahu batas server sebelum pengguna menemukannya, dan bisa membaca
hasilnya dengan benar.

Prasyarat: root, satu target HTTP. Kalau belum ada, siapkan dua target
pembanding:

```bash
mkdir -p /srv/backend
printf 'backend ok\n' > /srv/backend/index.html
yes 'data uji gzip untuk nginx' | head -c 4096 > /srv/backend/big.txt
cd /srv/backend && nohup python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 &
sleep 2
curl -s http://127.0.0.1:8080/
```

```bash
apt-get install -y wrk apache2-utils

# 2 thread, 20 koneksi, 5 detik
wrk -t2 -c20 -d5s --latency http://127.0.0.1:8080/big.txt

# pembanding
ab -q -n 500 -c20 -k http://127.0.0.1:8080/big.txt
```

Angka acuan di Debian 13.1, 1 vCPU: nginx menyajikan file 4 KB sekitar 7.700
req/s, sedangkan `python3 -m http.server` sekitar 1.100 req/s. Selisih itu bukan
tuning, itu batas server contoh.

Verifikasi:

```bash
wrk -t2 -c20 -d5s http://127.0.0.1:8080/big.txt | grep -E 'requests in|Non-2xx|Requests/sec'
cat /proc/loadavg
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `unable to connect` | target mati atau alamat salah | `ss -tlnp \| grep 8080`, cek URL |
| `Non-2xx` tinggi | backend membalas error, atau ada rate limit | cek log akses, matikan `limit_req` sementara |
| `Socket errors: connect` | backlog penuh, `ulimit -n` kecil | naikkan `net.core.somaxconn`, `LimitNOFILE` |
| Hasil tidak stabil | mesin dipakai hal lain | jalankan dari VM terpisah, durasi pendek |

Jebakan:
- `-t` lebih besar dari jumlah vCPU membuat hasil bias. Di 1 vCPU, `-t1` paling
  bersih.
- Angka RPS tanpa melihat `Non-2xx` menyesatkan. 429 dijawab nginx tanpa
  menyentuh backend, jadi terlihat lebih cepat.
- Load test di mesin yang sama dengan yang diuji membuat SSH tersendat. Jalankan
  dari VM lain, durasi 5 sampai 10 detik.

### k6 (DOKUMENTASI)

```bash
apt-get install -y gnupg
curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  > /etc/apt/sources.list.d/k6.list
apt-get update && apt-get install -y k6
k6 version
```

Skrip minimal `load.js`:

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
  const res = http.get('http://127.0.0.1:8080/');
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);
}
```

```bash
k6 run load.js
```

k6 tidak ada di repo Debian dan butuh repo Grafana. wrk cukup untuk latihan ini.
