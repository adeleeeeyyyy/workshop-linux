# Topik 1 — Security Hardening & Access Control

Estimasi waktu: **100 menit** (5 sub-topik).

Lingkungan uji fact-check: Debian GNU/Linux 13.1 (trixie), 1 vCPU, 1 GB RAM,
OpenSSH 10.0p2, sudo 1.9.16p2, ufw 0.36.2, fail2ban 1.1.0, tailscale 1.104.7.
Semua perintah di bawah benar-benar dijalankan di mesin uji tersebut pada
14 November 2026, kecuali yang ditandai DOKUMENTASI.

## Prasyarat / kondisi awal VM

- Akses SSH sebagai `root` (dari workshop sebelumnya).
- Repo apt aktif dan bisa internet: `apt-get update` sukses.
- Belum ada user non-root, belum ada UFW, belum ada fail2ban.
  Cek cepat:

```bash
getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}'   # harus kosong
which ufw fail2ban-client 2>/dev/null                        # harus kosong
```

- Punya satu jendela SSH kedua yang tetap terbuka ke VM selama latihan
  (lihat Titik rawan #1). Ini bukan formalitas: tanpa ini satu typo di
  `sshd_config` = terkunci.

---

## 1.1 Manajemen user non-root & privilege (sudo) — 15 menit

Tujuan: berhenti bekerja sebagai `root` setiap saat. Root hanya untuk darurat,
pekerjaan harian pakai user dengan `sudo` yang tercatat di log.

### Langkah 1 — Install sudo dan buat user

```bash
apt-get update
apt-get install -y sudo
adduser ops
```

`adduser ops` menanyakan password (2x), lalu nama lengkap dan field lain —
semua boleh di-Enter kosong.

Kenapa: image Debian minimal tidak selalu membawa paket `sudo`, jadi pastikan
dulu ada sebelum menggantungkan akses admin padanya.

Output yang diharapkan (potongan):

```
Adding user `ops' ...
Creating home directory `/home/ops' ...
```

Kalau akun peserta sudah ada di image lab, lewati langkah ini.

### Langkah 2 — Masukkan ke grup sudo

```bash
usermod -aG sudo ops
```

Kenapa `-a` penting: `usermod -G sudo ops` **tanpa** `-a` mengganti seluruh
grup tambahan user, bukan menambah. Kalau user sudah punya grup lain
(mis. `docker`), grup itu hilang diam-diam.

**Checkpoint**

```bash
id ops
getent group sudo
sudo -l -U ops
```

Harus muncul:

```
uid=1000(ops) gid=1000(ops) groups=1000(ops),27(sudo),100(users)
sudo:x:27:ops
User ops may run the following commands on <host>:
    (ALL : ALL) ALL
```

### Langkah 3 — Uji dari sesi user, bukan dari root

```bash
su - ops
sudo whoami
```

Ketik password `ops` saat diminta. Output harus `root`. Keluar dengan `exit`.

Kenapa: `sudo -l -U ops` hanya membaca konfigurasi. Yang membuktikan
privilege benar-benar bekerja adalah menjalankannya.

### Versi yang diuji

Diuji di Debian 13.1: `sudo 1.9.16p2`, baris `/etc/sudoers` nomor 50 berisi
`%sudo ALL=(ALL:ALL) ALL` (paket sudo default). Pada Ubuntu 24.04 sama
(`%sudo ALL=(ALL:ALL) ALL`), hanya nomor barisnya berbeda.

---

## 1.2 SSH key-based authentication & matikan root login — 25 menit

Tujuan: password tidak lagi cukup untuk masuk, root tidak bisa login langsung,
dan hanya user yang terdaftar yang boleh membuka SSH.

### Langkah 1 — Buat key di PC peserta (bukan di server)

Di laptop/PC peserta:

```bash
ssh-keygen -t ed25519 -C "ops@laptop" -f ~/.ssh/lab_ed25519
```

Lalu kirim public key ke server. Cara paling aman (tanpa menempel manual):

```bash
ssh-copy-id -i ~/.ssh/lab_ed25519.pub ops@<IP-VM>
```

Verifikasi dari PC:

```bash
ssh -i ~/.ssh/lab_ed25519 ops@<IP-VM> 'id'
```

Harus langsung masuk tanpa diminta password.

Kenapa ed25519: lebih pendek, lebih cepat, dan tidak butuh parameter
kompatibilitas seperti RSA. `ssh-copy-id` menangani permission folder
`~/.ssh` (700) dan file `authorized_keys` (600) — dua hal yang paling sering
salah kalau menempel manual, dan penyebab nomor satu "key sudah dipasang tapi
masih diminta password".

### Langkah 2 — Tulis konfigurasi hardening terpisah

Jangan mengedit `/etc/ssh/sshd_config`. Debian dan Ubuntu membacanya lebih dulu
lalu memuat `sshd_config.d/*.conf`; file terpisah lebih mudah di-rollback dan
tidak bentrok saat paket OpenSSH di-update.

```bash
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers ops
EOF
```

Ganti `ops` kalau nama user peserta berbeda. Tambahkan user lain di baris yang
sama, mis. `AllowUsers ops admin`.

Kenapa `KbdInteractiveAuthentication no` juga: di beberapa distro
`PasswordAuthentication no` saja tidak cukup karena PAM masih menerima
challenge-response. Keduanya harus mati.

### Langkah 3 — Validasi SEBELUM restart

```bash
sshd -t
```

Tidak ada output = sintaks benar. Lalu lihat nilai efektif yang akan dipakai:

```bash
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractive|pubkeyauthentication|maxauthtries|allowusers)'
```

Harus muncul:

```
maxauthtries 3
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
allowusers ops
```

**Jangan** melewati `sshd -t` dan `sshd -T`. `sshd -t` hanya cek sintaks;
`sshd -T` yang membuktikan nilainya benar-benar berlaku (file di
`sshd_config.d` bisa kalah oleh baris sebelumnya di `sshd_config`).

### Langkah 4 — Restart dan uji dari sesi lain

```bash
systemctl restart ssh
systemctl is-active ssh
```

Dari PC, di jendela **baru** (jangan tutup sesi lama):

```bash
ssh -i ~/.ssh/lab_ed25519 ops@<IP-VM> 'id'    # harus berhasil
ssh root@<IP-VM> 'id'                          # harus ditolak
```

Output penolakan yang diharapkan: `root@<IP-VM>: Permission denied (publickey).`

Kalau `ops` gagal masuk, **kembalikan dulu** akses root sebelum debug:

```bash
mv /etc/ssh/sshd_config.d/99-hardening.conf /root/99-hardening.conf.off
systemctl restart ssh
```

### Versi yang diuji

- Debian 13.1, OpenSSH 10.0p2. `sshd -T` mencetak `allowusers ops`.
- Uji tolak root menghasilkan baris journal:
  `User root from 127.0.0.1 not allowed because not listed in AllowUsers`.
- Uji password login menghasilkan `Permission denied (publickey)` — tidak ada
  prompt password sama sekali.

---

## 1.3 Firewall dengan UFW — 20 menit

Tujuan: hanya port yang memang perlu yang terbuka ke jaringan.

### Langkah 1 — Install dan set kebijakan default

```bash
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
```

Kenapa dua perintah terpisah: `ufw default deny incoming` mengubah kebijakan,
tapi firewall belum aktif. Urutan ini penting — lihat Titik rawan #2.

### Langkah 2 — Buka SSH LEBIH DULU

```bash
ufw allow 22/tcp
ufw status verbose
```

Harus muncul `22/tcp ALLOW IN Anywhere` dengan `Status: inactive`.

### Langkah 3 — Aktifkan

```bash
ufw --force enable
ufw status verbose
```

Output yang diharapkan:

```
Firewall is active and enabled on system startup
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
22/tcp                     ALLOW IN    Anywhere
```

`--force` menghindari prompt interaktif "Command may disrupt existing ssh
connections (y|n)". Aman dipakai **setelah** langkah 2.

### Langkah 4 — Verifikasi bahwa port lain benar-benar tertutup

Dari PC peserta, di luar sesi SSH:

```bash
curl -m 5 -o /dev/null -w '%{http_code}\n' http://<IP-VM>/
```

Hasil yang diharapkan: `000` dengan curl exit 28 (timeout) — port 80 tertutup.
Ini kondisi normal dan sengaja; port web dibuka di Topik 2.

Sertakan juga bukti backend firewall-nya (di Debian 13, ufw memakai
`iptables-nft`):

```bash
iptables -L -n | head -8
nft list ruleset | head -20
```

Akan terlihat rantai `ufw-*` di tabel `ip filter` dengan komentar
`# Warning: table ip filter is managed by iptables-nft, do not touch!`.

### Versi yang diuji

Debian 13.1: `ufw 0.36.2-9`, `iptables 1.8.11-2` (backend nft), `nftables 1.1.3-1`.
`ufw allow 80,443/tcp` membuat **satu** rule gabungan, bukan dua.

---

## 1.4 Proteksi brute-force otomatis (Fail2Ban) — 25 menit

Tujuan: IP yang gagal login berulang diblokir otomatis selama 10 menit.

### Langkah 1 — Install dan lihat default Debian

```bash
apt-get install -y fail2ban
fail2ban-client --version
cat /etc/fail2ban/jail.d/defaults-debian.conf
```

Output yang diharapkan:

```
Fail2Ban v1.1.0
[DEFAULT]
banaction = nftables
banaction_allports = nftables[type=allports]

[sshd]
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
enabled = true
```

Kenapa penting: paket Debian sudah mengaktifkan jail `sshd` dan memakai
`nftables` sebagai aksi ban. Jangan menyalin tutorial lama yang memakai
`iptables-multiport` — di Debian 13 hasilnya tetap jalan tapi aturannya
bercampur dengan ufw dan lebih sulit diaudit.

`backend = systemd` juga bukan pilihan bebas: Debian 13 tidak lagi memasang
`rsyslog` secara default, jadi **tidak ada** `/var/log/auth.log`. Filter yang
membaca file itu akan diam saja tanpa error.

### Langkah 2 — Tulis kebijakan di `jail.local`

```bash
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 198.51.100.0/24
bantime  = 10m
findtime = 10m
maxretry = 3

[sshd]
enabled = true
backend = systemd
EOF
```

Ganti `198.51.100.0/24` dengan IP kantor/PC instruktur. `198.51.100.0/24`
adalah blok dokumentasi (TEST-NET-2) — sengaja dipakai supaya tidak ada IP
nyata yang ke-whitelist tanpa sadar.

Validasi dan jalankan:

```bash
fail2ban-client -t
systemctl restart fail2ban
fail2ban-client status
fail2ban-client status sshd
```

Harus muncul `Jail list: sshd` dan `Currently failed: 0`.

### Langkah 3 — Uji end-to-end (dari PC lain, bukan dari server itu sendiri)

Dari VM teman / PC instruktur (IP harus beda dari server):

```bash
for i in 1 2 3 4; do ssh -o BatchMode=yes baduser$i@<IP-VM> true; done
```

Lalu di server:

```bash
fail2ban-client status sshd
fail2ban-client get sshd banip
nft list table inet f2b-table
```

Output yang diharapkan di server:

```
|- Total failed:     4
|- Currently banned: 1
`- Banned IP list:   <IP-penyerang>
```

```
table inet f2b-table {
        set addr-set-sshd {
                type ipv4_addr
                elements = { <IP-penyerang> }
        }
        chain f2b-chain {
                type filter hook input priority filter - 1; policy accept;
                tcp dport 22 ip saddr @addr-set-sshd reject with icmp port-unreachable
        }
}
```

Dan dari mesin penyerang, koneksi berikutnya langsung ditolak:

```
ssh: connect to host <IP-VM> port 22: Connection refused
```

Bersihkan setelah uji:

```bash
fail2ban-client set sshd unbanip <IP-penyerang>
```

Kenapa harus dari IP lain: fail2ban punya aturan bawaan `ignoreself` — semua
koneksi dari host itu sendiri (termasuk `127.0.0.1`) **tidak pernah** dihitung.
Kalau peserta menguji dari server itu sendiri, hasilnya selalu `Total failed: 0`
dan terlihat seperti konfigurasi rusak padahal benar.

### Versi yang diuji

Debian 13.1, `fail2ban 1.1.0-8`. Hasil uji nyata: `Total failed: 4`,
ban `172.23.3.1`, tabel `inet f2b-table` berisi 1 elemen, penyerang menerima
`Connection refused`, `unbanip` memulihkan akses seketika.

---

## 1.5 Private network tunneling (Tailscale) — 15 menit

Tujuan: server bisa diakses lewat IP privat Tailscale tanpa membuka port apa pun
di firewall publik. Alternatif WireGuard klasik ada di bagian akhir.

### Langkah 1 — Install dari repo resmi

```bash
apt-get install -y curl
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  -o /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install -y tailscale
tailscale version
```

Output yang diharapkan: `1.104.7` (atau lebih baru).

### Langkah 2 — Jalankan service dan login

```bash
systemctl enable --now tailscaled
systemctl is-active tailscaled
tailscale up --accept-dns=false
```

Output yang diharapkan: sebuah URL `https://login.tailscale.com/a/...`.
Buka URL itu di browser, login, lalu mesin muncul di tailnet.

```bash
tailscale status
tailscale ip -4
```

Kenapa `--accept-dns=false` di lab: kalau DNS diarahkan ke MagicDNS, VM lab
yang tidak punya akses keluar bisa kehilangan resolusi nama dan peserta
mengira jaringannya rusak. Nyalakan nanti kalau memang perlu.

Untuk otomatisasi (banyak VM), pakai auth key yang dibuat di admin console:

```bash
tailscale up --authkey tskey-auth-xxxxx --hostname vm-peserta-01 --accept-dns=false
```

Jangan menaruh auth key di script yang di-commit. Simpan di
`/etc/tailscale/authkey` dengan `chmod 600` lalu `source` dari script.

### Langkah 3 — Verifikasi

```bash
tailscale status          # tampilkan daftar node + IP 100.x
tailscale ip -4           # IP privat node ini
ping -c2 <IP-tailscale-teman>
```

### Versi yang diuji

Debian 13.1, `tailscale 1.104.7`. Yang **dijalankan**: install repo, service
start, dan `tailscale up` sampai keluar login URL
(`https://login.tailscale.com/a/...`). Penyelesaian login (butuh akun
Tailscale) dan ping antar-node tidak dijalankan — lihat tabel fact-check.

Catatan lingkungan: di container LXC tanpa `/dev/net/tun`, `tailscaled` gagal
start. Workaround untuk uji: `tailscaled --tun=userspace-networking`. Pada VM
peserta (KVM/Proxmox VM) `/dev/net/tun` ada, jadi tidak perlu workaround.

### Alternatif: WireGuard klasik (DOKUMENTASI)

```bash
apt-get install -y wireguard
umask 077
wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
cat > /etc/wireguard/wg0.conf <<'EOF'
[Interface]
Address = 10.88.0.1/24
ListenPort = 51820
PrivateKey = <isi server.key>

[Peer]
PublicKey = <public key laptop>
AllowedIPs = 10.88.0.2/32
EOF
systemctl enable --now wg-quick@wg0
wg show
```

Tambahkan `ufw allow 51820/udp`. WireGuard butuh modul kernel `wireguard`;
tidak bisa diuji di container LXC (modul tidak tersedia) — status
BELUM TERVERIFIKASI untuk langkah ini.

---

## Titik rawan

### 1. Terkunci dari SSH (paling sering terjadi)

Pemicu: `AllowUsers ops` ditulis sebelum key `ops` terbukti bekerja, atau
`PermitRootLogin no` diaktifkan sementara satu-satunya akses adalah root.

Pencegahan:
- Selalu punya sesi SSH kedua yang terbuka (yang sudah login tetap hidup
  walau konfigurasi baru menolak koneksi baru).
- Uji `sshd -t` **dan** `sshd -T` sebelum restart.
- Uji login user baru dari jendela baru **sebelum** menutup sesi root.

Rollback (dari sesi yang masih hidup):

```bash
mv /etc/ssh/sshd_config.d/99-hardening.conf /root/99-hardening.conf.off
systemctl restart ssh
sshd -T | grep -Ei 'permitrootlogin|allowusers'
```

Kalau semua sesi sudah hilang: buka console VM lewat Proxmox (`pct enter` untuk
LXC, console VNC untuk VM), lakukan rollback di atas.

### 2. `ufw enable` sebelum `allow 22` = koneksi SSH mati

`ufw --force enable` langsung menerapkan `deny incoming`. Kalau rule 22 belum
ada, koneksi yang sedang berjalan biasanya tetap hidup (state `ESTABLISHED`
diizinkan) tetapi koneksi **baru** mati.

Pencegahan: urutannya selalu `allow 22` → `ufw --force enable` → verifikasi dari
sesi baru.

Rollback lewat console: `ufw disable`.

### 3. UFW dan Docker saling menimpa

Kalau nanti peserta memasang Docker, Docker menulis aturan sendiri di tabel
`nat`/`filter` dan **melewati** UFW: container bisa terbuka ke publik walau
`ufw status` terlihat aman. Ini tidak dibahas di modul ini (tidak ada Docker di
outline), tapi disebut supaya peserta tidak kaget di workshop berikutnya.

### 4. Fail2ban "tidak bekerja" padahal jalan

Penyebab paling umum: menguji dari server itu sendiri (`ignoreself`), atau
mengharapkan `/var/log/auth.log` yang tidak ada di Debian 13.
Cek: `fail2ban-client status sshd` → lihat `Journal matches`.

### 5. `usermod -G` tanpa `-a`

Menghapus grup tambahan user. Selalu `usermod -aG`.

---

## Troubleshooting

| Gejala | Penyebab | Solusi |
|---|---|---|
| `Permission denied (publickey)` padahal key sudah di `authorized_keys` | Permission salah: `~/.ssh` bukan 700, `authorized_keys` bukan 600, atau home dir 777 | `chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; chown -R ops:ops ~/.ssh`. Cek juga `sshd -T \| grep authorizedkeysfile` |
| `sudo: ops is not in the sudoers file` | User belum masuk grup `sudo`, atau belum login ulang setelah `usermod` | `usermod -aG sudo ops`, lalu logout/login (grup dibaca saat login) |
| `ufw: command not found` setelah install | Paket gagal terinstall karena `apt-get update` belum jalan | `apt-get update && apt-get install -y ufw` |
| `fail2ban-client status sshd` → `Total failed: 0` terus | Diuji dari host itu sendiri (`ignoreself`), atau jail tidak membaca journal | Uji dari IP lain; `fail2ban-client get sshd journalmatch`; `journalctl -u ssh -n 20` |
| `tailscaled` gagal start: `tun: operation not permitted` | Tidak ada `/dev/net/tun` (container) | Pakai VM, atau `tailscaled --tun=userspace-networking` untuk uji |
| `sshd -t` lolos tapi konfigurasi tidak berlaku | Baris lain di `/etc/ssh/sshd_config` menang | `sshd -T` untuk lihat nilai efektif; beri nama file `99-*` agar dibaca terakhir |

---

## FACT-CHECK

Semua diuji di Debian 13.1 (trixie), 1 vCPU/1 GB, 14 November 2026, kecuali
ditandai lain.

| Langkah | Klaim yang dicek | Status | Bukti | Sumber |
|---|---|---|---|---|
| 1.1.1 | `apt-get install -y sudo` menyediakan `sudo` di Debian 13 minimal | DIJALANKAN | `Setting up sudo (1.9.16p2-3+deb13u2)` | https://wiki.debian.org/sudo |
| 1.1.2 | `usermod -aG sudo ops` membuat `ops` bisa `sudo` penuh | DIJALANKAN | `id ops` → `groups=1000(ops),27(sudo),100(users)`; `sudo -l -U ops` → `(ALL : ALL) ALL` | https://manpages.debian.org/trixie/passwd/usermod.8.en.html |
| 1.1.3 | Grup `sudo` sudah punya baris sudoers di Debian | DIJALANKAN | `/etc/sudoers:50:%sudo ALL=(ALL:ALL) ALL` | https://wiki.debian.org/sudo |
| 1.2.1 | `ssh-copy-id` memasang key dan login tanpa password berhasil | DIJALANKAN | `ssh -i ops_testkey ops@<vm> 'id'` → `uid=1000(ops)` | https://manpages.debian.org/trixie/openssh-client/ssh-copy-id.1.en.html |
| 1.2.2 | Konfigurasi di `sshd_config.d/99-*.conf` benar dan lolos validasi | DIJALANKAN | `sshd -t` → rc=0, tanpa output | https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html |
| 1.2.3 | Nilai efektif: `permitrootlogin no`, `passwordauthentication no`, `allowusers ops` | DIJALANKAN | `sshd -T` → `permitrootlogin no` / `passwordauthentication no` / `kbdinteractiveauthentication no` / `maxauthtries 3` / `allowusers ops` | https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html |
| 1.2.4 | Login root ditolak setelah hardening | DIJALANKAN | `root@127.0.0.1: Permission denied (publickey).` + journal `User root from 127.0.0.1 not allowed because not listed in AllowUsers` | https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html |
| 1.2.5 | Login password ditolak setelah hardening | DIJALANKAN | `ops@127.0.0.1: Permission denied (publickey).` (tanpa prompt password) | https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html |
| 1.3.1 | `ufw 0.36.2` tersedia di repo Debian 13 | DIJALANKAN | `ufw 0.36.2 / Copyright 2008-2023 Canonical Ltd.` | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 1.3.2 | `ufw default deny incoming` + `allow 22/tcp` + `--force enable` menghasilkan status active | DIJALANKAN | `Firewall is active and enabled on system startup`; `22/tcp ALLOW IN Anywhere` | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 1.3.3 | UFW di Debian 13 memakai backend iptables-nft | DIJALANKAN | `iptables -L -n` menampilkan rantai `ufw-*`; `nft list ruleset` menampilkan `# Warning: table ip filter is managed by iptables-nft` | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 1.3.4 | Port 80 tertutup dari host lain saat UFW aktif | DIJALANKAN | Dari laptop: `curl` → `host_http=000 rc=28` (timeout) | https://manpages.debian.org/trixie/ufw/ufw.8.en.html |
| 1.4.1 | Paket Debian mengaktifkan jail sshd dengan backend systemd + banaction nftables | DIJALANKAN | `/etc/fail2ban/jail.d/defaults-debian.conf` → `banaction = nftables`, `backend = systemd`, `enabled = true` | https://github.com/fail2ban/fail2ban/blob/master/config/jail.conf |
| 1.4.2 | Debian 13 tidak punya `/var/log/auth.log` (tanpa rsyslog) | DIJALANKAN | `ls /var/log/auth.log` → `No such file or directory`; `dpkg -l rsyslog` → 0 terpasang | https://wiki.debian.org/UnattendedUpgrades (konteks paket minimal), https://github.com/fail2ban/fail2ban/wiki/Proper-firewall-rules-for-Systemd |
| 1.4.3 | `jail.local` dengan maxretry 3 memblokir IP setelah 4 kegagalan | DIJALANKAN | `Total failed: 4`, `Currently banned: 1`, `Banned IP list: 172.23.3.1` | https://manpages.debian.org/trixie/fail2ban/fail2ban-client.1.en.html |
| 1.4.4 | Ban ditegakkan lewat tabel nftables dan menolak koneksi | DIJALANKAN | `nft list table inet f2b-table` → `tcp dport 22 ip saddr @addr-set-sshd reject with icmp port-unreachable`; penyerang dapat `Connection refused` | https://github.com/fail2ban/fail2ban/wiki/Proper-firewall-rules-for-Systemd |
| 1.4.5 | `unbanip` memulihkan akses | DIJALANKAN | Setelah unban: `Currently banned: 0`, percobaan berikutnya dapat `Permission denied` (bukan `refused`) | https://manpages.debian.org/trixie/fail2ban/fail2ban-client.1.en.html |
| 1.4.6 | Fail2ban mengabaikan koneksi dari host sendiri | DIJALANKAN | `/var/log/fail2ban.log` → `Ignore 127.0.0.1 by ignoreself rule` | https://github.com/fail2ban/fail2ban/blob/master/config/jail.conf |
| 1.5.1 | Instalasi Tailscale dari repo resmi Debian trixie berhasil | DIJALANKAN | `tailscale version` → `1.104.7`; `tailscale commit: fb3b9b2...` | https://tailscale.com/kb/1031/install-linux |
| 1.5.2 | `tailscale up` mengeluarkan login URL | DIJALANKAN | `https://login.tailscale.com/a/g48174ed90b032ad8` | https://tailscale.com/kb/1080/cli |
| 1.5.3 | Penyelesaian login & ping antar-node | BELUM TERVERIFIKASI | Butuh akun Tailscale; tidak dijalankan | https://tailscale.com/kb/1017/install |
| 1.5.4 | `tailscaled` gagal di container tanpa `/dev/net/tun`; workaround `--tun=userspace-networking` | DIJALANKAN | `mknod: /dev/net/tun: Operation not permitted`; `systemctl is-active tailscaled` → `failed`; mode userspace → `Logged out.` | https://tailscale.com/kb/1112/userspace-networking |
| 1.5.5 | WireGuard butuh modul kernel, tidak bisa diuji di LXC | BELUM TERVERIFIKASI | `modprobe: FATAL: Module wireguard not found in directory /lib/modules/7.0.2-6-pve` | https://www.wireguard.com/quickstart/ |
