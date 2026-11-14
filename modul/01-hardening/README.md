# Modul 1: Security Hardening & Access Control

Setiap sub-topik berdiri sendiri. Jalankan dari VM yang baru di-install, tanpa
bergantung pada sub-topik lain.

Konvensi seluruh modul:
- `<user>` nama user admin Anda, mis. `adly`.
- `<IP-VM>` IP VM, mis. `10.10.10.20`.
- Semua perintah dijalankan sebagai `root` (login root atau `su -`).
- OS acuan Debian 13.1, OpenSSH 10.0p2.

---

## 1.1 User admin non-root dan sudo

Hasil: satu user `<user>` yang bisa menjalankan perintah admin lewat `sudo`.

Prasyarat: akses root, repo apt aktif.

```bash
apt-get update
apt-get install -y sudo

# buat user, password ditanyakan dua kali
adduser <user>

# -a wajib. Tanpa -a, grup lain milik user ikut terhapus
usermod -aG sudo <user>
```

Verifikasi:

```bash
id <user>                     # harus memuat 27(sudo)
sudo -l -U <user>             # harus berakhir (ALL : ALL) ALL
su - <user> -c 'sudo whoami'  # keluarkan: root
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `not in the sudoers file` | user belum masuk grup `sudo`, atau sesi lama | ulangi `usermod -aG sudo <user>`, logout lalu login |
| `adduser: command not found` | image sangat minimal | `apt-get install -y adduser` |
| `sudo` minta password yang tidak pernah diset | user dibuat `--disabled-password` | `passwd <user>` |

Jebakan: `usermod -G sudo <user>` mengganti seluruh grup tambahan user. Pakai
`-aG`.

---

## 1.2 SSH key dan matikan login root

Hasil: login hanya dengan key, root tidak bisa login langsung, hanya `<user>`
yang boleh masuk.

Prasyarat: `<user>` ada dan punya sudo (lihat 1.1). Satu sesi SSH kedua sudah
terbuka dan belum ditutup sampai verifikasi selesai.

```bash
# 1. di PC peserta: buat key, kirim public key
ssh-keygen -t ed25519 -C "<user>@laptop" -f ~/.ssh/lab
ssh-copy-id -i ~/.ssh/lab.pub <user>@<IP-VM>

# 2. di server: file terpisah, jangan edit sshd_config
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers <user>
EOF

# 3. validasi. Wajib dua-duanya
sshd -t
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractive|pubkeyauthentication|maxauthtries|allowusers)'

# 4. terapkan
systemctl restart ssh
```

Verifikasi dari jendela baru di PC:

```bash
ssh -i ~/.ssh/lab <user>@<IP-VM>   # masuk tanpa password
ssh root@<IP-VM>                   # Permission denied (publickey)
```

Rollback kalau `<user>` gagal masuk:

```bash
mv /etc/ssh/sshd_config.d/99-hardening.conf /root/
systemctl restart ssh
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `Permission denied (publickey)` padahal key sudah dikirim | permission salah | `chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; chown -R <user>:<user> ~/.ssh` |
| Config tidak berlaku setelah restart | baris lain di `sshd_config` menang | cek `sshd -T`, beri nama file `99-*` |
| Semua sesi hilang | `AllowUsers` ditulis sebelum key diuji | masuk lewat console Proxmox, jalankan rollback |

Jebakan:
- `sshd -t` hanya cek sintaks. `sshd -T` membuktikan nilai efektif.
- `PermitRootLogin no` mematikan root walau key root terpasang.
- Setelah password auth mati, `ssh-copy-id` untuk user baru tidak bisa dipakai.
  Simpan satu key cadangan.

---

## 1.3 Firewall dengan UFW

Hasil: semua port masuk ditolak kecuali yang dibuka eksplisit.

Prasyarat: root, akses SSH aktif.

```bash
apt-get install -y ufw

ufw default deny incoming
ufw default allow outgoing

# buka SSH sebelum firewall aktif
ufw allow 22/tcp

ufw --force enable
ufw status verbose
```

Verifikasi dari PC:

```bash
curl -m 5 -o /dev/null -w '%{http_code}\n' http://<IP-VM>/   # 000, timeout
timeout 2 bash -c "</dev/tcp/<IP-VM>/22" && echo "22 terbuka"
```

Cek backend kernel (Debian 13 memakai iptables-nft):

```bash
iptables -L -n | head -8
nft list ruleset | head -20
```

Rollback:

```bash
ufw disable
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| SSH mati setelah `ufw enable` | `allow 22` belum ada | console Proxmox, lalu `ufw disable` |
| `ufw: command not found` | `apt-get update` belum jalan | update lalu install |
| Aplikasi tidak bisa diakses dari luar | port belum dibuka | `ufw allow <port>/tcp`, atau lewat reverse proxy |

Jebakan:
- Urutan `enable` sebelum `allow 22` mengunci koneksi baru. Koneksi aktif
  biasanya tetap hidup, jadi gejalanya bisa tertunda.
- Docker menulis aturan sendiri dan melewati UFW. Container bisa terbuka walau
  `ufw status` terlihat aman.
- `ufw allow 80,443/tcp` membuat satu rule gabungan.

---

## 1.4 Blokir brute-force dengan Fail2Ban

Hasil: IP yang gagal login berulang diblokir otomatis sesuai `bantime` di
`jail.local`.

Prasyarat: root, SSH aktif, satu mesin lain untuk menguji serangan.

```bash
apt-get install -y fail2ban

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

fail2ban-client -t
systemctl restart fail2ban
fail2ban-client status sshd
```

`198.51.100.0/24` blok dokumentasi. Ganti dengan subnet Anda.

Uji dari mesin lain:

```bash
for i in 1 2 3 4; do ssh -o BatchMode=yes baduser$i@<IP-VM> true; done
```

Verifikasi di server:

```bash
fail2ban-client status sshd      # Total failed 4, Banned IP list berisi IP penyerang
fail2ban-client get sshd banip
nft list table inet f2b-table
```

Hapus ban setelah uji:

```bash
fail2ban-client set sshd unbanip <IP-penyerang>
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `Total failed: 0` | diuji dari server itu sendiri, kena `ignoreself` | uji dari IP lain |
| Jail aktif tapi tidak memblokir | tidak ada `/var/log/auth.log` di Debian 13 | pakai `backend = systemd` |
| `status sshd` error | jail tidak aktif | `fail2ban-client status`, pastikan `enabled = true` |

Jebakan:
- `ignoreself` aktif default. Uji dari loopback selalu menghasilkan nol.
- Log auth hanya di journal, karena Debian 13 tidak memasang `rsyslog`.
- Kalau semua user sudah pakai key, "Failed password" tidak muncul lagi. Filter
  tetap menangkap `Invalid user` dan `Connection closed`.

---

## 1.5 Akses privat dengan Tailscale

Hasil: VM punya IP privat `100.x` yang bisa diakses perangkat lain tanpa membuka
port di firewall publik.

Prasyarat: root, internet keluar, akun Tailscale, `/dev/net/tun` ada (VM biasa
punya, container LXC belum tentu).

```bash
apt-get install -y curl

curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  -o /etc/apt/sources.list.d/tailscale.list

apt-get update
apt-get install -y tailscale

systemctl enable --now tailscaled
tailscale up --accept-dns=false
```

Buka URL login yang dicetak, login di browser, lalu:

```bash
tailscale status
tailscale ip -4
ping -c2 <IP-tailscale-perangkat-lain>
```

Untuk banyak VM, pakai auth key:

```bash
tailscale up --authkey tskey-auth-xxxxx --hostname vm-01 --accept-dns=false
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `tailscaled` failed, `tun: operation not permitted` | tidak ada `/dev/net/tun` | pakai VM, atau `tailscaled --tun=userspace-networking` |
| `tailscale up` tidak mengeluarkan URL | service mati | `systemctl status tailscaled`, `journalctl -u tailscaled -n 30` |
| Node tidak muncul di admin console | login browser belum selesai | ulangi `tailscale up`, buka URL baru |

Jebakan:
- Auth key setara password. Simpan di `/etc/tailscale/authkey` mode 600, bukan di
  script yang di-commit.
- `--accept-dns=false` mencegah VM lab kehilangan resolusi nama saat MagicDNS
  aktif.
- Tailscale butuh UDP 41641 keluar. Kalau diblokir, trafik lewat relay DERP dan
  lebih lambat.

### Alternatif: WireGuard (demo instruktur)

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

Tambahkan `ufw allow 51820/udp`. Butuh modul kernel `wireguard`, tidak bisa
diuji di container.
