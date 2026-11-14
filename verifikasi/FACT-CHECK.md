# Fact-check

Mesin uji: Debian GNU/Linux 13.1 (trixie), 1 vCPU, 1 GB RAM, kernel
7.0.2-6-pve, container LXC privileged. Tanggal uji 14 November 2026.

Status:
- DIJALANKAN: perintah dieksekusi di mesin uji, output cocok.
- DOKUMENTASI: dicocokkan dengan dokumentasi resmi, tidak dieksekusi.
- BELUM TERVERIFIKASI: tidak bisa dipastikan.

Script reproduksi ada di `../fc/`. Setiap baris bukti diambil dari output
script tersebut. Nama host di kutipan mengikuti mesin uji (`hello.lab.test`),
sedangkan modul memakai placeholder `<domain>`.

## Ringkasan

| Status | Jumlah |
|---|---|
| DIJALANKAN | 82 |
| DOKUMENTASI | 6 |
| BELUM TERVERIFIKASI | 3 |

## Modul 1: Security Hardening

| Langkah | Klaim | Status | Bukti | Sumber |
|---|---|---|---|---|
| 1.1 | `apt-get install -y sudo` menyediakan sudo | DIJALANKAN | `Setting up sudo (1.9.16p2-3+deb13u2)` | https://wiki.debian.org/sudo |
| 1.1 | `usermod -aG sudo` memberi sudo penuh | DIJALANKAN | `id ops` memuat `27(sudo)`; `sudo -l -U ops` berakhir `(ALL : ALL) ALL` | https://manpages.debian.org/trixie/passwd/usermod.8.en.html |
| 1.1 | Baris sudoers grup sudo ada di Debian | DIJALANKAN | `/etc/sudoers:50:%sudo ALL=(ALL:ALL) ALL` | https://wiki.debian.org/sudo |
| 1.2 | `ssh-copy-id` lalu login key tanpa password | DIJALANKAN | `ssh -i ops_testkey ops@<vm> id` menghasilkan `uid=1000(ops)` | https://manpages.debian.org/trixie/openssh-client/ssh-copy-id.1.en.html |
| 1.2 | `sshd -t` lolos untuk konfigurasi hardening | DIJALANKAN | rc=0, tanpa output | https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html |
| 1.2 | `sshd -T` menunjukkan nilai efektif | DIJALANKAN | `permitrootlogin no`, `passwordauthentication no`, `kbdinteractiveauthentication no`, `maxauthtries 3`, `allowusers ops` | https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html |
| 1.2 | Login root ditolak | DIJALANKAN | `root@127.0.0.1: Permission denied (publickey).` | https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html |
| 1.2 | Login password ditolak | DIJALANKAN | `ops@127.0.0.1: Permission denied (publickey).`, tanpa prompt password | https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html |
| 1.3 | `allow 22` lalu `--force enable` menghasilkan status active | DIJALANKAN | `Firewall is active and enabled on system startup`; `22/tcp ALLOW IN Anywhere` | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 1.3 | UFW memakai backend iptables-nft di Debian 13 | DIJALANKAN | `iptables -L -n` menampilkan rantai `ufw-*`; nft menampilkan komentar `managed by iptables-nft` | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 1.3 | Port 80 tertutup dari host lain | DIJALANKAN | dari laptop `curl` menghasilkan `000 rc=28` | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 1.3 | Cek port tanpa paket tambahan | DIJALANKAN | `timeout 2 bash -c "</dev/tcp/127.0.0.1/22"` berhasil, port 9999 tertutup | https://www.gnu.org/software/bash/manual/html_node/Redirections.html |
| 1.4 | Jail sshd Debian memakai systemd dan banaction nftables | DIJALANKAN | `defaults-debian.conf`: `banaction = nftables`, `backend = systemd`, `enabled = true` | https://github.com/fail2ban/fail2ban/blob/master/config/jail.conf |
| 1.4 | Debian 13 tanpa rsyslog tidak punya `/var/log/auth.log` | DIJALANKAN | `ls /var/log/auth.log` gagal; `systemctl is-active rsyslog` menghasilkan `inactive` | https://manpages.debian.org/trixie/rsyslog/rsyslogd.8.en.html |
| 1.4 | maxretry 3 memblokir setelah 4 percobaan | DIJALANKAN | `Total failed: 4`, `Currently banned: 1`, `Banned IP list: 172.23.3.1` | https://manpages.debian.org/trixie/fail2ban/fail2ban-client.1.en.html |
| 1.4 | Ban ditegakkan lewat tabel nftables | DIJALANKAN | `tcp dport 22 ip saddr @addr-set-sshd reject with icmp port-unreachable`; penyerang dapat `Connection refused` | https://github.com/fail2ban/fail2ban/wiki/Proper-firewall-rules-for-Systemd |
| 1.4 | `unbanip` memulihkan akses | DIJALANKAN | `Currently banned: 0`; percobaan berikutnya `Permission denied` | https://manpages.debian.org/trixie/fail2ban/fail2ban-client.1.en.html |
| 1.4 | `ignoreself` membuat uji dari lokal tidak terhitung | DIJALANKAN | `fail2ban.log`: `Ignore 127.0.0.1 by ignoreself rule` | https://github.com/fail2ban/fail2ban/blob/master/config/jail.conf |
| 1.5 | Install Tailscale dari repo resmi berhasil | DIJALANKAN | `tailscale version` menghasilkan `1.104.7` | https://tailscale.com/kb/1031/install-linux |
| 1.5 | `tailscale up` mengeluarkan URL login | DIJALANKAN | `https://login.tailscale.com/a/g48174ed90b032ad8` | https://tailscale.com/kb/1080/cli |
| 1.5 | Login sampai node aktif dan ping antar node | BELUM TERVERIFIKASI | butuh akun Tailscale | https://tailscale.com/kb/1017/install |
| 1.5 | `tailscaled` gagal tanpa `/dev/net/tun` | DIJALANKAN | `mknod: /dev/net/tun: Operation not permitted`; service `failed`; mode userspace memberi `Logged out.` | https://tailscale.com/kb/1112/userspace-networking |
| 1.5 | WireGuard butuh modul kernel | BELUM TERVERIFIKASI | `modprobe: FATAL: Module wireguard not found` | https://www.wireguard.com/quickstart/ |

## Modul 2: Web dan Performance

| Langkah | Klaim | Status | Bukti | Sumber |
|---|---|---|---|---|
| 2.1 | `useradd --system --no-create-home --shell /usr/sbin/nologin` membuat user service | DIJALANKAN | `appsvc:x:999:991::/home/appsvc:/usr/sbin/nologin` | https://manpages.debian.org/trixie/passwd/useradd.8.en.html |
| 2.1 | Unit `Type=simple` dengan `User=` berjalan dan listen di loopback | DIJALANKAN | `systemctl show -p User` menghasilkan `appsvc`; `ss -tlnp` menampilkan `127.0.0.1:8080` dipegang `python3` PID 24900 | https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html |
| 2.1 | Port yang sudah dipakai membuat service gagal dan restart berulang | DIJALANKAN | `MainPID 0`, status `activating`; setelah port bebas `NRestarts=26` dan service `active` | https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html |
| 2.1 | `Restart=on-failure` me-restart proses yang di-`kill -9` | DIJALANKAN | PID berubah, `NRestarts=1`, journal memuat `Scheduled restart job, restart counter is at 1` | https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html |
| 2.1 | `EnvironmentFile` mode 600 terbaca systemd | DIJALANKAN | `-rw------- root root /etc/demo/demo.env`, service `active` | https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html |
| 2.2 | Backend contoh `python3 -m http.server` melayani port 8080 | DIJALANKAN | `halo dari python http.server`; `LISTEN 127.0.0.1:8000` pada uji stateless | https://docs.python.org/3/library/http.server.html |
| 2.2 | `proxy_pass` dan `server_name` dari `/etc/hosts` menghasilkan 200 | DIJALANKAN | `curl http://app.lab.test/` mengembalikan JSON demo, `status=200`; `getent hosts app.lab.test` menghasilkan `127.0.0.1` | https://nginx.org/en/docs/http/ngx_http_proxy_module.html |
| 2.3 | `openssl req -x509 -addext subjectAltName` membuat SAN benar | DIJALANKAN | `X509v3 Subject Alternative Name: DNS:hello.lab.test`; `notAfter=Nov 14 08:32:18 2027 GMT` | https://docs.openssl.org/3.5/man1/openssl-req/ |
| 2.3 | `http2 on;` diterima nginx 1.26.3 | DIJALANKAN | `nginx -t` sukses; respons `HTTP/2 200` | https://nginx.org/en/docs/http/ngx_http_ssl_module.html |
| 2.3 | Redirect 80 ke 443 | DIJALANKAN | `301 -> https://hello.lab.test/` | https://nginx.org/en/docs/http/ngx_http_ssl_module.html |
| 2.3 | curl tanpa `-k` menolak self-signed | DIJALANKAN | `curl: (60) SSL certificate problem: self-signed certificate` | https://curl.se/docs/sslcerts.html |
| 2.3 | Certbot butuh domain publik | DOKUMENTASI | tidak dijalankan, domain `.test` tidak bisa divalidasi | https://certbot.eff.org/instructions |
| 2.3 | Cloudflare Tunnel butuh akun | DOKUMENTASI | tidak dijalankan | https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/ |
| 2.4 | `gzip on;` duplikat menggagalkan reload | DIJALANKAN | `[emerg] "gzip" directive is duplicate in /etc/nginx/conf.d/tuning.conf:1`; `Reload failed`; `grep -n gzip /etc/nginx/nginx.conf` menghasilkan `47: gzip on;` | https://nginx.org/en/docs/http/ngx_http_gzip_module.html |
| 2.4 | Dua file `conf.d` menulis direktif sama juga gagal | DIJALANKAN | `[emerg] "gzip_comp_level" directive is duplicate in /etc/nginx/conf.d/tuning.conf:2` | https://nginx.org/en/docs/http/ngx_http_gzip_module.html |
| 2.4 | gzip mengecilkan 4096 byte jadi sekitar 72 byte | DIJALANKAN | `gzip=72`, `plain=4096`, header `Content-Encoding: gzip` dan `Vary: Accept-Encoding` | https://nginx.org/en/docs/http/ngx_http_gzip_module.html |
| 2.4 | Respons kecil di bawah `gzip_min_length` tidak dikompres | DIJALANKAN | tidak ada `Content-Encoding` pada respons 73 byte | https://nginx.org/en/docs/http/ngx_http_gzip_module.html |
| 2.4 | `X-Cache-Status` menunjukkan MISS lalu HIT | DIJALANKAN | urutan `MISS`, `HIT`, `HIT` | https://nginx.org/en/docs/http/ngx_http_proxy_module.html |
| 2.4 | Cache bertahan melewati restart, EXPIRED setelah TTL | DIJALANKAN | `MISS`, restart, `HIT`, `sleep 11`, `EXPIRED`, lalu `HIT` | https://nginx.org/en/docs/http/ngx_http_proxy_module.html |
| 2.4 | nginx membuat sendiri direktori cache | DIJALANKAN | `/var/cache/nginx/site` ada, milik `www-data`, tanpa `mkdir` manual | https://nginx.org/en/docs/http/ngx_http_proxy_module.html |
| 2.4 | `limit_req_status 429` membalas 429 | DIJALANKAN | 43.588 dari 43.658 request Non-2xx; log `"GET / HTTP/1.1" 429 162` | https://nginx.org/en/docs/http/ngx_http_limit_req_module.html |
| 2.4 | Setelah uji beban, IP sendiri kena 429 sementara | DIJALANKAN | `curl` langsung setelah wrk menghasilkan `429`; `sleep 3` menghasilkan `200` | https://nginx.org/en/docs/http/ngx_http_limit_req_module.html |
| 2.4 | Rate limit tidak menghukum IP lain | DIJALANKAN | dari laptop saat server kena limit: `200` | https://nginx.org/en/docs/http/ngx_http_limit_req_module.html |

## Modul 3: Monitoring dan Stress Test

| Langkah | Klaim | Status | Bukti | Sumber |
|---|---|---|---|---|
| 3.1 | `journalctl -u <unit>` menampilkan stdout service | DIJALANKAN | `python3[3543]: 127.0.0.1 "GET / HTTP/1.1" 200 -` | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| 3.1 | `-p err -b` menyaring error boot sekarang | DIJALANKAN | muncul `Reload failed for nginx.service` | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| 3.1 | `--disk-usage` melaporkan ukuran journal | DIJALANKAN | `Archived and active journals take up 16M` | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| 3.1 | Output `-o json` memuat field terstruktur | DIJALANKAN | `{'_COMM': 'python3', 'PRIORITY': '6', '_SYSTEMD_UNIT': 'hello.service'}` | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| 3.1 | `journalctl -p err -b \| wc -l` menghasilkan angka | DIJALANKAN | `4` | https://www.freedesktop.org/software/systemd/man/latest/journalctl.html |
| 3.2 | `htop 3.4.1` dan `ncdu 1.22` tersedia | DIJALANKAN | `htop 3.4.1`, `ncdu 1.22` | https://manpages.debian.org/trixie/htop/htop.1.en.html |
| 3.2 | `df -h` dan `df -i` menunjukkan blok vs inode | DIJALANKAN | `15G 906M 14G 7% /` dan `983040 25030 958010 3% /` | https://manpages.debian.org/trixie/coreutils/df.1.en.html |
| 3.2 | `du -xh --max-depth=1` mengurutkan pemakaian | DIJALANKAN | `352M /var`, `157M /var/lib`, `142M /var/cache` | https://manpages.debian.org/trixie/coreutils/du.1.en.html |
| 3.2 | `ncdu -1 -o` menghasilkan JSON | DIJALANKAN | `[1,2,{"progname":"ncdu","progver":"1.22"` | https://dev.yorhel.nl/ncdu/man |
| 3.2 | `ss -tulpn` menampilkan proses pemilik port | DIJALANKAN | `users:(("nginx",pid=3584,fd=5))` di `0.0.0.0:80` | https://manpages.debian.org/trixie/iproute2/ss.8.en.html |
| 3.2 | Load container mengikuti host | DIJALANKAN | container membaca `31.67 31.68 31.61`; host membaca `30.57 31.45 31.53` | https://manpages.debian.org/trixie/procps/uptime.1.en.html |
| 3.3 | Netdata tidak ada di repo Debian | DIJALANKAN | `apt-cache policy netdata` menghasilkan `(none)` | https://github.com/netdata/netdata/blob/master/packaging/installer/README.md |
| 3.3 | Kickstart memasang netdata 2.12.3 dan service aktif | DIJALANKAN | `Successfully installed the Netdata Agent.`, `netdata v2.12.3`, `active` | https://github.com/netdata/netdata/blob/master/packaging/installer/README.md |
| 3.3 | API lokal merespons di 19999 | DIJALANKAN | `{"version":"v2.12.3","hosts-available":1,...}` | https://learn.netdata.cloud/docs/agent/web/api |
| 3.3 | Netdata memakai sekitar 60 MB RSS | DIJALANKAN | `4486 59960 netdata`; `free -m` used 149 MB | https://github.com/netdata/netdata/blob/master/packaging/installer/README.md |
| 3.3 | Port 19999 hanya terbuka untuk subnet admin | DIJALANKAN | sebelum rule `000 rc=28`; sesudah `ufw allow from 192.168.11.0/24` menjadi `200` | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 3.3 | Netdata tanpa autentikasi bawaan | DOKUMENTASI | dashboard terbuka tanpa kredensial, tidak ada uji login | https://learn.netdata.cloud/docs/netdata-agent/configuration |
| 3.4 | `wrk` tersedia di repo Debian | DIJALANKAN | `wrk 4.1.0 [epoll]` | https://github.com/wg/wrk |
| 3.4 | nginx menyajikan file 4 KB sekitar 7.700 req/s di 1 vCPU | DIJALANKAN | `38753 requests in 5.01s`, `Requests/sec: 7738.13` | https://github.com/wg/wrk |
| 3.4 | `python3 -m http.server` sekitar 1.100 req/s | DIJALANKAN | `5734 requests in 5.00s`, `Requests/sec: 1146.01` | https://github.com/wg/wrk |
| 3.4 | `ab` memberi angka pembanding | DIJALANKAN | `Complete requests: 500`, `Requests per second: 3457.38` | https://httpd.apache.org/docs/2.4/programs/ab.html |
| 3.4 | k6 butuh repo Grafana | DOKUMENTASI | hanya URL key yang dicek, paket tidak dipasang | https://grafana.com/docs/k6/latest/set-up/install-k6/ |

## Modul 4: Backup, Alerting, Automation

| Langkah | Klaim | Status | Bukti | Sumber |
|---|---|---|---|---|
| 4.1 | `unattended-upgrades 2.12` dan `20auto-upgrades` berisi dua baris Periodik | DIJALANKAN | `ii unattended-upgrades 2.12`; `APT::Periodic::Unattended-Upgrade "1";` | https://wiki.debian.org/UnattendedUpgrades |
| 4.1 | Pola origin default Debian | DIJALANKAN | `50unattended-upgrades` memuat 3 baris `origin=Debian` | https://wiki.debian.org/UnattendedUpgrades |
| 4.1 | Timer apt-daily aktif | DIJALANKAN | `Sun 2026-11-15 02:10:41 UTC apt-daily.timer`; semua `enabled` | https://wiki.debian.org/UnattendedUpgrades |
| 4.1 | `--dry-run` menampilkan paket target tanpa menjalankan | DIJALANKAN | log: `Packages that will be upgraded: apt apt-utils ... zlib1g` (93 paket) | https://manpages.debian.org/trixie/unattended-upgrades/unattended-upgrade.8.en.html |
| 4.1 | Log hasil upgrade tersedia | DIJALANKAN | `unattended-upgrades.log` 2061 byte, memuat `All upgrades installed` | https://manpages.debian.org/trixie/unattended-upgrades/unattended-upgrade.8.en.html |
| 4.1 | Mesin uji punya MTA lokal | DIJALANKAN | `ii postfix 3.10.4`; `systemctl is-active postfix` menghasilkan `active` | https://www.postfix.org/documentation.html |
| 4.2 | `sqlite3 .backup` menghasilkan dump konsisten | DIJALANKAN | `app-2026-11-14_0839.db` 8192 byte | https://sqlite.org/cli.html |
| 4.2 | Script menghasilkan arsip dan sha256 | DIJALANKAN | `OK /var/backups/app/app-2026-11-14_0954.tar.gz 376 bytes`; `.sha256` 110 byte | https://manpages.debian.org/trixie/tar/tar.1.en.html |
| 4.2 | `tar -C /` menghasilkan path relatif tanpa warning | DIJALANKAN | `tar tzf` memuat `srv/data/`, `srv/data/app.conf`, `srv/data/db/app.db` | https://manpages.debian.org/trixie/tar/tar.1.en.html |
| 4.2 | Ekspansi `${SRC#/}` untuk `-C /` | DIJALANKAN | `tar czf arsip -C / srv/data` menghasilkan `srv/data/`, `srv/data/app.conf` | https://manpages.debian.org/trixie/tar/tar.1.en.html |
| 4.2 | `sha256sum -c` memverifikasi arsip | DIJALANKAN | `/var/backups/app/app-2026-11-14_0954.tar.gz: OK` | https://manpages.debian.org/trixie/coreutils/sha256sum.1.en.html |
| 4.2 | Retensi `-mtime +7 -delete` hanya menghapus arsip tua | DIJALANKAN | `find -print` hanya mendaftar `hello-2020-01-01_0000.tar.gz`; setelah backup berikutnya file itu hilang | https://manpages.debian.org/trixie/findutils/find.1.en.html |
| 4.2 | `pg_dump -Fc` dan `mysqldump --single-transaction` | DOKUMENTASI | tidak ada server PostgreSQL/MySQL di mesin uji | https://www.postgresql.org/docs/current/app-pgdump.html |
| 4.3 | `cron 3.0pl1-197` aktif di image | DIJALANKAN | `ii cron 3.0pl1-197`; `systemctl is-active cron` menghasilkan `active` | https://manpages.debian.org/trixie/cron/cron.8.en.html |
| 4.3 | File `/etc/cron.d` dibaca dan dieksekusi | DIJALANKAN | `journalctl -u cron`: `(root) CMD (/usr/local/bin/check-disk.sh)` pada 08:45:01 dan 09:00:01 | https://manpages.debian.org/trixie/cron/crontab.5.en.html |
| 4.3 | Restore selektif mengembalikan file identik | DIJALANKAN | `sha256sum /srv/data/app.conf` sama sebelum dan sesudah `tar xzf ... -C / srv/data/app.conf`; isi kembali `konfigurasi penting` | https://manpages.debian.org/trixie/diffutils/diff.1.en.html |
| 4.3 | Script berjalan dengan environment minimal | DIJALANKAN | `env -i /bin/bash -c '/usr/local/bin/backup.sh'` menghasilkan `OK ... 382 bytes` | https://manpages.debian.org/trixie/coreutils/env.1.en.html |
| 4.4 | `notify.sh` mengirim POST urlencoded ke endpoint bot | DIJALANKAN | `PATH=/bot<token>/sendMessage`, `BODY=chat_id=...&text=%5Btesting-debian%5D...` | https://core.telegram.org/bots/api#sendmessage |
| 4.4 | `check-disk.sh` senyap di bawah ambang | DIJALANKAN | `THRESHOLD=99` tanpa output, rc=0, disk 14% | https://manpages.debian.org/trixie/coreutils/df.1.en.html |
| 4.4 | `check-disk.sh` mengirim saat ambang terlampaui | DIJALANKAN | `THRESHOLD=1` menghasilkan `sent: [testing-debian] DISK 14% (ambang 1%)` | https://manpages.debian.org/trixie/coreutils/df.1.en.html |
| 4.4 | Kegagalan alert tidak menggagalkan backup | DIJALANKAN | backup selesai, `curl: (22) ... 401` tercatat, `alert gagal` masuk ke log | https://core.telegram.org/bots/api#sendmessage |
| 4.4 | Token palsu ditolak Telegram | DIJALANKAN | `curl: (22) The requested URL returned error: 401` | https://core.telegram.org/bots/api |
| 4.4 | Payload Discord `{content: ...}` | DOKUMENTASI | `jq` terpasang, webhook Discord tidak tersedia untuk diuji | https://discord.com/developers/docs/resources/webhook#execute-webhook |
| 4.4 | Kirim nyata dengan token valid | BELUM TERVERIFIKASI | butuh token dan akun nyata | https://core.telegram.org/bots/api |

## Catatan lingkungan

- Mesin uji container LXC. `/proc/loadavg` mengikuti host, jadi angka load di
  dokumentasi modul 3 berasal dari host, bukan container.
- WireGuard dan `/dev/net/tun` tidak tersedia di container. Pada VM biasa
  keduanya ada.
- Angka throughput hanya berlaku untuk 1 vCPU. Jangan dipakai sebagai patokan
  produksi.
