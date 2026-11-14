# "Server Linux Sudah Jadi, Terus Apa?"

Modul praktik lanjutan dari workshop **"Bangun Server Linux dari 0"**.

Setiap langkah di modul ini dijalankan dan diverifikasi di mesin uji
(`root@172.23.1.88`, Debian GNU/Linux 13.1 trixie, 1 vCPU, 1 GB RAM,
kernel 7.0.2-6-pve) pada 14 November 2026. Langkah yang tidak bisa dijalankan di
lab (butuh akun pihak ketiga atau domain publik) ditandai **DOKUMENTASI** atau
**BELUM TERVERIFIKASI** — bukan diklaim sebagai sudah diuji.

## Daftar modul

| No | Topik | Sub-topik | Waktu |
|----|-------|-----------|-------|
| 1 | [Security Hardening & Access Control](modul/01-hardening/README.md) | User non-root + sudo, SSH key & disable root login, UFW, Fail2Ban, Tailscale/WireGuard | 100 menit |
| 2 | [Web, Service & Performance Readiness](modul/02-web/README.md) | Custom systemd service, nginx reverse proxy, HTTPS self-signed/Let's Encrypt/Cloudflare, gzip + cache + rate limit | 110 menit |
| 3 | [Monitoring, Log Inspection & Stress Testing](modul/03-monitoring/README.md) | journalctl & /var/log, htop/df/ncdu/ss, Netdata, wrk/ab/k6 | 70 menit |
| 4 | [Backup, Alerting & Automation](modul/04-backup/README.md) | unattended-upgrades, bash backup file+DB, cron + disaster recovery, alert Telegram/Discord | 80 menit |

Total 360 menit (6 jam) + istirahat = 1 hari kerja.

## Kondisi awal VM peserta

Modul ini berasumsi VM sudah dalam kondisi akhir workshop pertama:

- Debian 13 (trixie), systemd sebagai init, `cron` terpasang, `rsyslog`
  **tidak** terpasang.
- Akses `root` via SSH dari PC peserta.
- Repo apt aktif dan VM bisa internet (untuk `apt-get`, netdata kickstart,
  tailscale repo).
- Python 3.13 tersedia (`python3`), belum ada nginx/ufw/fail2ban.

Kalau base image peserta berbeda (mis. Ubuntu 24.04 LTS), baca bagian
**Asumsi & yang perlu diverifikasi manual** di bawah sebelum mengajar.

## Struktur repo

```
workshop-adeli/
├── README.md                  <- file ini: ringkasan, asumsi, cheat sheet
├── modul/
│   ├── 01-hardening/README.md
│   ├── 02-web/README.md
│   ├── 03-monitoring/README.md
│   └── 04-backup/README.md
└── fc/                        <- script fact-check yang benar-benar dijalankan di VM uji
    ├── s1.sh        user, sudo, SSH hardening (dengan watchdog anti-lockout)
    ├── s2.sh        ufw + install fail2ban, cek default Debian
    ├── s3.sh..s5.sh fail2ban end-to-end: ban, nft set, unban, A/B journalmatch
    ├── s6.sh..s8.sh tailscale (repo, service, login URL, mode userspace)
    ├── s10.sh       systemd service + nginx reverse proxy
    ├── s11.sh       TLS self-signed + tuning (percobaan pertama, gagal: gzip duplikat)
    ├── s11b.sh      TLS + tuning setelah diperbaiki
    ├── s12.sh       gzip, cache, wrk baseline vs rate limit
    ├── s13.sh       journalctl, /var/log, htop/df/ncdu/ss, wrk+ab
    ├── s14.sh       instalasi netdata
    ├── s16.sh       unattended-upgrades, backup, cron, restore
    ├── s17.sh       alerting (versi pertama, gagal: override env)
    ├── s17b.sh      alerting setelah diperbaiki (payload tertangkap)
    ├── s20.sh       backup versi modul, uji retensi, env -i, cron journal
    ├── s21.sh       versi final backup script
    ├── s22.sh       uji cache: bertahan setelah restart, EXPIRED setelah TTL
    └── (tidak ada private key di repo — key uji dibuat ulang saat fact-check)
```

Script di `fc/` disimpan sebagai jejak bukti — setiap baris "Bukti" di tabel
fact-check berasal dari output script ini.

---

# (a) Ringkasan fact-check

| Status | Jumlah langkah |
|---|---|
| DIJALANKAN | 83 |
| DOKUMENTASI | 6 |
| BELUM TERVERIFIKASI | 4 |
| **Total** | **93** |

Rincian per topik:

| Topik | Langkah | DIJALANKAN | DOKUMENTASI | BELUM TERVERIFIKASI |
|---|---|---|---|---|
| 1 — Hardening & Access | 23 | 21 | 0 | 2 |
| 2 — Web & Performance | 22 | 20 | 2 | 0 |
| 3 — Monitoring & Stress | 24 | 21 | 2 | 1 |
| 4 — Backup & Alerting | 24 | 21 | 2 | 1 |

## Yang berstatus DOKUMENTASI (6)

| Topik | Item | Alasan tidak dijalankan |
|---|---|---|
| 2 | Certbot / Let's Encrypt | domain `.test` tidak bisa divalidasi HTTP-01 dari internet |
| 2 | Cloudflare Tunnel | butuh akun + domain Cloudflare |
| 3 | Netdata tanpa autentikasi bawaan | hanya dicek dokumentasinya, tidak diuji login |
| 3 | Instalasi k6 dari repo Grafana | hanya dicek URL key (`200`), paket tidak dipasang |
| 4 | Payload Discord `{content: ...}` | tidak ada webhook Discord untuk diuji |
| 4 | `pg_dump -Fc` / `mysqldump --single-transaction` | tidak ada server PostgreSQL/MySQL di lab |

## Yang berstatus BELUM TERVERIFIKASI (4)

| Topik | Item | Yang belum terbukti |
|---|---|---|
| 1 | Penyelesaian login Tailscale + ping antar-node | butuh akun Tailscale; hanya sampai login URL |
| 1 | WireGuard (bagian alternatif) | modul kernel `wireguard` tidak tersedia di container uji |
| 3 | Uptime Kuma butuh Docker ~150–250 MB RAM | tidak dipasang; angka dari dokumentasi proyek |
| 4 | Pengiriman nyata ke bot Telegram/Discord | hanya sampai respons `401` dengan token palsu |

## Temuan yang mengubah isi modul (bukan sekadar catatan)

Empat hal ini ditemukan **karena** perintahnya benar-benar dijalankan, dan
salah satunya akan membuat modul gagal total kalau hanya ditulis dari teori:

1. **`gzip on;` duplikat** — paket nginx Debian sudah menaruh `gzip on;` di
   `/etc/nginx/nginx.conf:47`. Menambahkannya lagi di `conf.d/` membuat
   `nginx -t` gagal, `reload` ditolak, dan **nginx tetap jalan dengan config
   lama** sehingga HTTPS tidak pernah aktif. Modul sekarang hanya menulis
   parameter gzip, bukan `gzip on;`.
2. **`/var/log/auth.log` tidak ada di Debian 13** (tanpa rsyslog) — jail
   fail2ban berbasis file log akan diam tanpa error. Modul memakai
   `backend = systemd` (default Debian) dan menyebut ini di troubleshooting.
3. **Fail2ban `ignoreself`** — menguji dari server itu sendiri selalu memberi
   `Total failed: 0`. Modul mewajibkan uji serangan dari IP lain.
4. **`sshd_config.d/99-*.conf` tanpa uji `sshd -T`** — `sshd -t` hanya cek
   sintaks; nilai efektif bisa kalah oleh baris di `sshd_config`. Modul
   menjadikan `sshd -T` sebagai checkpoint wajib, plus sesi SSH kedua.

---

# (b) Asumsi & yang perlu diverifikasi manual

## Asumsi lingkungan

1. VM peserta = Debian 13.x (trixie), systemd, `cron` aktif, tanpa `rsyslog`.
   Semua nomor versi di modul mengacu ke kondisi ini.
2. Spesifikasi 1 vCPU / 1 GB RAM / disk 15 GB. Semua angka throughput
   (`wrk` 4.6–6.3k req/s, netdata 60 MB RSS) hanya berlaku untuk spesifikasi ini
   dan **tidak boleh** dipakai sebagai patokan produksi.
3. Peserta punya **dua** jendela SSH selama Topik 1 (satu untuk kerja, satu
   cadangan). Instruktur perlu menegaskan ini sebelum mulai.
4. Nama host lab `hello.lab.test` dipetakan lewat `/etc/hosts`. Tidak ada DNS
   internal di lab.
5. Peserta boleh membuat akun pihak ketiga (Tailscale, Telegram bot, Discord
   webhook). Kalau tidak, sub-topik 1.5 dan 4.4 menjadi demo instruktur.
6. Mesin uji adalah container LXC privileged di Proxmox. Untuk semua langkah
   kecuali WireGuard dan Tailscale, perilakunya identik dengan VM biasa.
7. Alur modul dijalankan **berurutan pada satu VM uji** (Topik 1 → 4), tetapi
   bukan oleh peserta baru mulai dari VM kosong. Satu kali dry-run bersama
   peserta tetap perlu untuk mengukur waktu dan menemukan salah paham.

## Yang perlu diverifikasi manual sebelum mengajar

| # | Item | Cara verifikasi |
|---|---|---|
| 1 | **Ubuntu 24.04 LTS** sebagai base image | Ubuntu 22.10+ memakai *socket activation* untuk SSH: `systemctl restart ssh` belum tentu memuat config baru — kemungkinan perlu `systemctl restart ssh.socket`. **Belum diuji di modul ini.** Kalau memakai Ubuntu, uji ulang 1.2 Langkah 4 |
| 2 | Paket `sudo` sudah ada di base image Ubuntu/Debian tertentu | `dpkg -l sudo` — kalau sudah ada, Langkah 1.1.1 cukup `apt-get install -y sudo` (idempoten, aman) |
| 3 | Nomor baris `%sudo` di `/etc/sudoers` | di Debian 13 = baris 50; di distro lain bisa beda — modul menyebutnya sebagai contoh, bukan patokan |
| 4 | Durasi nyata tiap topik | 100/110/70/80 menit adalah estimasi penulisan, **belum** diukur dengan 15 peserta. Ukur di dry-run dengan 2–3 orang |
| 5 | Tailscale end-to-end | login dengan akun asli, `tailscale status` menampilkan 2 node, `ping <IP-tailscale>` sukses, ACL sesuai |
| 6 | Token Telegram/Discord asli | isi `/etc/alert.env` dengan token nyata, jalankan `notify.sh "tes"`, pastikan pesan masuk (bukan `401`) |
| 7 | Let's Encrypt | butuh domain nyata + port 80 terjangkau. `certbot --nginx -d <domain>` lalu cek renewal `certbot renew --dry-run` |
| 8 | Cloudflare Tunnel | butuh akun + domain. Uji `cloudflared tunnel run` dan akses lewat hostname publik |
| 9 | WireGuard di VM nyata | `modprobe wireguard` harus sukses, lalu `wg show` setelah `wg-quick@wg0` aktif |
| 10 | k6 | pasang dari repo Grafana, jalankan `load.js` yang ada di 3.4.5, bandingkan threshold `p(95)<500` |
| 11 | Backup database sungguhan | jalankan `pg_dump -Fc` + `pg_restore` di server dengan data nyata; ukur waktu restore |
| 12 | Kapasitas jaringan lab | 15 peserta × (`wrk` + netdata + tailscale) pada satu subnet bisa memenuhi uplink. Uji beban sebaiknya bergiliran |
| 13 | Kebutuhan disk base image | setelah semua topik, VM uji memakai 1.9 GB (14% dari 15 GB). Sisakan ≥ 2 GB agar netdata + cache nginx muat |

## Risiko mengajar yang perlu diantisipasi

- **Terkunci SSH** adalah kegagalan paling mahal (butuh console Proxmox).
  Siapkan prosedur console di kertas untuk instruktur.
- **Port 80/443 diblokir UFW** sampai 2.2 Langkah 4 — pastikan peserta tidak
  panik dan menganggap nginx rusak.
- **Rate limit 429** membuat `curl` biasa tampak gagal setelah load test;
  tunggu 3 detik (sudah didokumentasikan).
- **netdata kickstart** butuh internet dan ~1 menit; kalau jaringan lab lambat,
  jalankan paralel di awal topik 3.

---

# (c) Cheat sheet — satu halaman

## Akses & keamanan

```bash
adduser ops && usermod -aG sudo ops        # user admin non-root
id ops; sudo -l -U ops                     # verifikasi privilege
ssh-keygen -t ed25519 -C "ops@laptop"      # key di PC peserta
ssh-copy-id -i ~/.ssh/lab_ed25519.pub ops@<IP-VM>

sshd -t                                    # cek sintaks config
sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|allowusers'
systemctl restart ssh

ufw default deny incoming
ufw allow 22/tcp                           # SELALU sebelum enable
ufw allow 80,443/tcp
ufw --force enable
ufw status numbered

fail2ban-client status sshd                # jail aktif?
fail2ban-client get sshd banip
fail2ban-client set sshd unbanip <IP>
nft list table inet f2b-table              # bukti ban di kernel

systemctl enable --now tailscaled
tailscale up --accept-dns=false
tailscale status; tailscale ip -4
```

## Service & web

```bash
systemctl daemon-reload                    # setelah edit unit file
systemctl enable --now hello
systemctl status hello; systemctl is-active hello
systemctl show -p MainPID -p User -p NRestarts --value hello
kill -9 $(systemctl show -p MainPID --value hello)   # uji auto-restart

nginx -t && systemctl reload nginx         # reload graceful
nginx -T | grep -E 'limit_req|proxy_cache'
ss -tlnp | grep -E ':80|:443|:8080'

openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /etc/ssl/private/x.key -out /etc/ssl/certs/x.crt \
  -subj "/CN=hello.lab.test" -addext "subjectAltName=DNS:hello.lab.test"

curl -sk https://hello.lab.test/           # -k hanya untuk self-signed
curl -sk -I https://hello.lab.test/ | grep -i x-cache-status
curl -sk -H 'Accept-Encoding: gzip' -o /dev/null -w '%{size_download}\n' https://hello.lab.test/big
```

## Log & resource

```bash
journalctl -u <unit> -n 50 --no-pager
journalctl -p err -b                       # error boot sekarang
journalctl --since '-10 min' -u nginx
journalctl --disk-usage
journalctl --vacuum-size=200M

df -h /; df -i /                           # blok vs inode
du -xh --max-depth=1 /var | sort -h | tail
ncdu /var
free -h; cat /proc/loadavg; nproc
ss -tulpn; ss -s
```

## Load test

```bash
wrk -t2 -c20 -d10s --latency https://hello.lab.test/
ab -q -n 500 -c20 -k https://hello.lab.test/
grep ' 429 ' /var/log/nginx/hello.access.log | tail -1
```

## Backup, cron, alert

```bash
unattended-upgrade --dry-run               # lihat, jangan jalankan
systemctl list-timers 'apt*'

/usr/local/bin/hello-backup.sh             # backup manual
tar tzf /var/backups/hello/*.tar.gz | head # cek isi
sha256sum -c /var/backups/hello/*.sha256   # cek integritas
tar xzf <arsip> -C / opt/hello/app.py      # restore SELEKTIF
env -i /bin/bash -c '/usr/local/bin/hello-backup.sh'   # simulasi cron

journalctl -u cron -n 20 --no-pager        # cron jalan atau tidak
/usr/local/bin/check-disk.sh               # cek ambang disk
/usr/local/bin/notify.sh "pesan uji"       # tes alert
```

---

# (d) Saran

Di luar outline, tidak dikerjakan di modul ini. Urut dari yang paling bernilai:

1. **Ansible untuk 15 VM** — seluruh modul ini adalah 15× pekerjaan manual yang
   identik. Satu playbook `site.yml` + inventory akan menghemat separuh waktu
   kelas, dan menjadi jembatan alami ke workshop DevOps berikutnya.
2. **`restic` atau `borg` menggantikan `tar`+`sha256`** — deduplikasi,
   enkripsi, dan retensi bawaan (`restic forget --keep-daily 7`). Kode lebih
   sedikit, jaminan lebih kuat. `tar` tetap dipakai di modul karena transparan
   untuk pemula.
3. **`systemd timer` sebagai pembanding cron** — 15 menit tambahan untuk
   menunjukkan `OnCalendar=`, `Persistent=true` (mengejar jadwal yang terlewat
   saat VM mati), dan log terstruktur di journal. Cron tidak punya
   `Persistent=true`.
4. **`logrotate` untuk nginx** — `/var/log/nginx/*.log` tumbuh tanpa batas di
   lab yang di-load test. Satu file config 6 baris.
5. **SSH 2FA (TOTP) atau port knocking** — lanjutan logis dari Topik 1, tapi
   menambah risiko terkunci dan butuh waktu praktik yang tidak tersedia.
6. **Prometheus + node_exporter** — kalau peserta akan lanjut ke Kubernetes,
   ini lebih relevan daripada Netdata. Netdata dipilih karena satu perintah.
7. **Audit hardening otomatis** — `lynis audit system` atau `ssh-audit`
   memberi skor sebelum/sesudah Topik 1, sehingga peserta melihat dampak
   pekerjaannya dalam satu angka.
8. **Latihan "server mati" tanpa diberi tahu** — di akhir hari, instruktur
   mematikan nginx/DB satu VM dan peserta harus mendiagnosis hanya dengan
   journalctl. Ini menguji Topik 3 secara nyata, bukan sebagai demo.
