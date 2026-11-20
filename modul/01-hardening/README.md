# Modul 1: Security Hardening & Access Control

Setiap sub-topik berdiri sendiri. Jalankan dari VM yang baru di-install, tanpa
bergantung pada sub-topik lain.

Konvensi seluruh modul:
- `<user>` nama user admin Anda, mis. `adly`.
- `<IP-VM>` IP VM, mis. `10.10.10.20`.
- `<IP-PC>` IP PC Anda, `<subnet-admin>` subnet PC Anda, mis. `192.168.20.0/24`.
- Label **[Server]** dijalankan di VM sebagai `root` (login root atau `su -`).
- Label **[PC Windows]** dijalankan di PowerShell Windows 10/11. OpenSSH client
  sudah bawaan Windows. Pengguna Linux atau macOS memakai padanan di README
  utama.
- File konfigurasi ditulis sebagai `File: <path>` lalu isinya. Edit sendiri
  dengan `nano <path>`, simpan `Ctrl+O` `Enter`, keluar `Ctrl+X`.
- OS acuan Debian 13.1, OpenSSH 10.0p2.

---

## 1.1 User admin non-root dan sudo

Hasil: satu user `<user>` yang bisa menjalankan perintah admin lewat `sudo`.

Paket: `sudo` dan `adduser`.

```bash
apt-get update
apt-get install -y sudo adduser
```

Prasyarat: akses root, repo apt aktif.

```bash
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

Paket: `openssh-server` (biasanya sudah terpasang).

```bash
apt-get install -y openssh-server
```

Prasyarat: `<user>` ada dan punya sudo (lihat 1.1). Satu sesi SSH kedua sudah
terbuka dan belum ditutup sampai verifikasi selesai.

**Langkah 1. [PC Windows]** buat key, lalu tampilkan public key-nya:

```powershell
ssh-keygen -t ed25519 -C "<user>@laptop" -f $env:USERPROFILE\.ssh\lab
type $env:USERPROFILE\.ssh\lab.pub
```

Salin satu baris keluaran `type` (diawali `ssh-ed25519`).

**Langkah 2. [Server]** siapkan folder dan tempel public key:

```bash
install -d -m 700 -o <user> -g <user> /home/<user>/.ssh
nano /home/<user>/.ssh/authorized_keys
```

File: `/home/<user>/.ssh/authorized_keys`

```text
ssh-ed25519 AAAA...isi-public-key-Anda... <user>@laptop
```

```bash
chown <user>:<user> /home/<user>/.ssh/authorized_keys
chmod 600 /home/<user>/.ssh/authorized_keys
```

**Langkah 3. [PC Windows]** uji key sebelum apa pun dimatikan:

```powershell
ssh -i $env:USERPROFILE\.ssh\lab <user>@<IP-VM>
```

Harus masuk tanpa diminta password. Kalau masih diminta password, berhenti di
sini dan lihat tabel error.

**Langkah 4. [Server]** buat file terpisah, jangan edit `sshd_config`.

File: `/etc/ssh/sshd_config.d/99-hardening.conf`

```text
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers <user>
```

**Langkah 5. [Server]** validasi, wajib dua-duanya, lalu terapkan:

```bash
sshd -t
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractive|pubkeyauthentication|maxauthtries|allowusers)'
systemctl restart ssh
```

Verifikasi dari jendela PowerShell baru:

```powershell
ssh -i $env:USERPROFILE\.ssh\lab <user>@<IP-VM>   # masuk tanpa password
ssh root@<IP-VM>                                  # Permission denied (publickey)
```

Rollback kalau `<user>` gagal masuk ([Server], lewat sesi kedua atau console):

```bash
mv /etc/ssh/sshd_config.d/99-hardening.conf /root/
systemctl restart ssh
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `Permission denied (publickey)` padahal key sudah ditempel | permission atau owner salah | `chmod 700 /home/<user>/.ssh; chmod 600 /home/<user>/.ssh/authorized_keys; chown -R <user>:<user> /home/<user>/.ssh` |
| `Permission denied (publickey)`, isi key terlihat benar | public key terpotong atau terpecah jadi dua baris | pastikan satu baris utuh, tempel ulang |
| `UNPROTECTED PRIVATE KEY FILE` di Windows | ACL file key terlalu longgar | `icacls $env:USERPROFILE\.ssh\lab /inheritance:r /grant:r "$($env:USERNAME):(R)"` |
| Config tidak berlaku setelah restart | baris lain di `sshd_config` menang | cek `sshd -T`, beri nama file `99-*` |
| Semua sesi hilang | `AllowUsers` ditulis sebelum key diuji | masuk lewat console Proxmox, jalankan rollback |

Jebakan:
- `sshd -t` hanya cek sintaks. `sshd -T` membuktikan nilai efektif.
- `PermitRootLogin no` mematikan root walau key root terpasang.
- Setelah password auth mati, key baru tidak bisa dipasang lewat password.
  Simpan satu key cadangan.
- Windows tidak punya `ssh-copy-id`. Karena itu key ditempel manual di
  `authorized_keys`.

---

## 1.3 Firewall dengan UFW

Hasil: semua port masuk ditolak kecuali yang dibuka eksplisit.

Paket: `ufw`.

```bash
apt-get install -y ufw
```

Prasyarat: root, akses SSH aktif.

```bash
ufw default deny incoming
ufw default allow outgoing

# buka SSH sebelum firewall aktif
ufw allow 22/tcp

ufw --force enable
ufw status verbose
```

Verifikasi dari **[PC Windows]**:

```powershell
curl.exe -m 5 -s -o NUL -w '%{http_code}' http://<IP-VM>/   # 000, timeout
Test-NetConnection <IP-VM> -Port 22                          # TcpTestSucceeded : True
```

Cek backend kernel di **[Server]** (Debian 13 memakai iptables-nft):

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
| `ufw: command not found` | paket belum dipasang | `apt-get update && apt-get install -y ufw` |
| Aplikasi tidak bisa diakses dari luar | port belum dibuka | `ufw allow <port>/tcp`, atau lewat reverse proxy |
| `curl` di PowerShell mencetak error aneh | `curl` adalah alias `Invoke-WebRequest` | pakai `curl.exe` |

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

Paket: `fail2ban`.

```bash
apt-get install -y fail2ban
```

Prasyarat: root, SSH aktif, PC Anda untuk menguji serangan. PC Anda akan
ikut diblokir selama `bantime`, jadi siapkan console VM untuk membuka blokir.

**[Server]** buat file konfigurasi jail.

File: `/etc/fail2ban/jail.local`

```text
[DEFAULT]
# jangan masukkan IP PC Anda di sini, kalau tidak, ban tidak akan terjadi
ignoreip = 127.0.0.1/8 ::1
bantime  = 2m
findtime = 10m
maxretry = 3

[sshd]
enabled = true
backend = systemd
```

```bash
fail2ban-client -t
systemctl restart fail2ban
fail2ban-client status sshd
```

Uji serangan dari **[PC Windows]** (user `baduser` memang tidak ada):

```powershell
foreach ($i in 1..4) { ssh -o BatchMode=yes "baduser$i@<IP-VM>" true }
```

Verifikasi di **[Server]**:

```bash
fail2ban-client status sshd      # Total failed 4, Banned IP list berisi IP PC
fail2ban-client get sshd banip
nft list table inet f2b-table
```

Dari PC, koneksi baru ke VM sekarang ditolak sampai ban habis (2 menit). Buka
blokir lebih cepat:

```bash
fail2ban-client set sshd unbanip <IP-PC>
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `Total failed: 0` | diuji dari server itu sendiri, kena `ignoreself` | uji dari PC, bukan dari VM |
| Jail aktif tapi tidak memblokir | tidak ada `/var/log/auth.log` di Debian 13 | pakai `backend = systemd` |
| `status sshd` error | jail tidak aktif | `fail2ban-client status`, pastikan `enabled = true` |
| PC tidak terblokir padahal gagal 4 kali | IP PC masuk `ignoreip` | hapus dari `ignoreip`, restart fail2ban |

Jebakan:
- `ignoreself` aktif default. Uji dari loopback selalu menghasilkan nol.
- Log auth hanya di journal, karena Debian 13 tidak memasang `rsyslog`.
- Kalau semua user sudah pakai key, "Failed password" tidak muncul lagi. Filter
  tetap menangkap `Invalid user` dan `Connection closed`.
- Ban menutup SSH dari IP itu saja. Sesi yang sudah terbuka tetap hidup.

---

## 1.5 Kontrol akses native: SSH, firewall, sudo

Hasil: SSH hanya bisa dimasuki dari `<subnet-admin>` oleh anggota grup
`sshusers`, fitur forwarding dimatikan, dan sudo dibatasi ke perintah tertentu.
Semuanya fitur bawaan Debian, tanpa akun tambahan.

Paket: `ufw`, `sudo`, `nginx` (nginx dipakai sebagai contoh perintah sudo).

```bash
apt-get install -y ufw sudo nginx
```

Prasyarat: 1.1 dan 1.2 selesai, `<subnet-admin>` dan `<IP-PC>` diketahui, satu
sesi SSH kedua terbuka dan belum ditutup sampai verifikasi selesai.

### 1.5.1 Batasi SSH ke grup dan subnet admin

**[Server]** buat grup khusus SSH dan masukkan user admin:

```bash
groupadd -f sshusers
usermod -aG sshusers <user>
```

Ubah baris `AllowUsers` di file dari 1.2. Jangan menambah baris baru, ganti
yang lama.

File: `/etc/ssh/sshd_config.d/99-hardening.conf`

```text
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers <user>@<subnet-admin>
```

Tambahkan kebijakan akses dan sesi di file baru.

File: `/etc/ssh/sshd_config.d/98-access.conf`

```text
AllowGroups sshusers
LoginGraceTime 30
MaxSessions 3
MaxStartups 5:30:20
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no

# pengecualian per sumber: hanya subnet admin boleh port forwarding.
# Match harus di bagian paling bawah file.
Match Address <subnet-admin>
    AllowTcpForwarding yes
```

Validasi. Wajib dua-duanya, `-C` mensimulasikan koneksi dari alamat tertentu:

```bash
sshd -t
sshd -T -C user=<user>,host=pc,addr=<IP-PC> | grep -Ei '^(allowusers|allowgroups|allowtcpforwarding|maxsessions)'
sshd -T -C user=<user>,host=x,addr=8.8.8.8  | grep -Ei '^allowtcpforwarding'
```

Baris pertama harus `allowtcpforwarding yes`, baris kedua `no`. Terapkan:

```bash
systemctl restart ssh
```

Verifikasi dari jendela **[PC Windows]** baru:

```powershell
ssh -i $env:USERPROFILE\.ssh\lab <user>@<IP-VM>                       # masuk
ssh -i $env:USERPROFILE\.ssh\lab -L 8080:localhost:80 <user>@<IP-VM> -N   # forwarding jalan, Ctrl+C untuk berhenti
```

Uji penolakan, dengan sesi kedua tetap terbuka. Ganti sementara subnet di
`AllowUsers` ke subnet yang bukan milik Anda:

File: `/etc/ssh/sshd_config.d/99-hardening.conf`

```text
AllowUsers <user>@10.99.99.0/24
```

```bash
sshd -t && systemctl restart ssh
```

Dari **[PC Windows]**, login harus ditolak walau key benar:

```powershell
ssh -i $env:USERPROFILE\.ssh\lab <user>@<IP-VM>   # Permission denied (publickey)
```

Alasannya tercatat di **[Server]**:

```bash
journalctl -u ssh -n 20 --no-pager | grep -i 'not allowed'
```

Kembalikan `AllowUsers <user>@<subnet-admin>` seperti semula, lalu
`sshd -t && systemctl restart ssh`.

Rollback penuh:

```bash
rm /etc/ssh/sshd_config.d/98-access.conf
```

Lalu ubah `AllowUsers` di `99-hardening.conf` kembali menjadi `AllowUsers <user>`
dan jalankan `sshd -t && systemctl restart ssh`.

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `Permission denied (publickey)` untuk user yang benar | user belum masuk `sshusers`, atau login dari luar subnet | `id <user>`, cek IP asal di journal |
| Batasan subnet tidak berlaku | baris `AllowUsers <user>` lama masih ada di file lain | `sshd -T \| grep allowusers`, harus hanya satu entri |
| `Match` tidak mengubah apa-apa | alamat PC bukan di `<subnet-admin>`, atau di belakang NAT | uji dengan `sshd -T -C addr=...` |
| `sshd -t` error `no argument after keyword` | baris direktif kosong | hapus atau isi baris itu |

Jebakan:
- Beberapa baris `AllowUsers` bersifat akumulatif: user lolos kalau cocok dengan
  salah satunya. `AllowUsers <user>` dari 1.2 yang dibiarkan akan membatalkan
  batasan subnet. Ganti barisnya, jangan ditambah.
- `AllowUsers` dan `AllowGroups` berlaku bersamaan, user harus lolos
  dua-duanya.
- `Match` di dalam file drop-in berlaku sampai akhir file itu. Letakkan di
  bagian paling bawah file.
- `AllowTcpForwarding no` bisa dilewati kalau user punya shell dan memasang
  tool tunnel sendiri. Ini mengurangi permukaan serangan, bukan batas keamanan
  mutlak.
- Admin yang IP-nya berubah (rumah, hotspot) akan terkunci. Simpan akses lewat
  console Proxmox.

### 1.5.2 Firewall berdasarkan sumber

Hasil: port 22 hanya terbuka untuk `<subnet-admin>`, bukan seluruh internet.

Prasyarat: UFW aktif dari 1.3. **[Server]**:

```bash
# tambah rule baru dulu, baru hapus rule lama
ufw allow from <subnet-admin> to any port 22 proto tcp
ufw status numbered
```

Uji dari **[PC Windows]** dalam sesi baru. Kalau masuk, lanjut hapus rule
lama di **[Server]**:

```bash
ufw delete allow 22/tcp
ufw status verbose
```

Verifikasi dari **[PC Windows]**:

```powershell
ssh -i $env:USERPROFILE\.ssh\lab <user>@<IP-VM>   # masuk
Test-NetConnection <IP-VM> -Port 22               # TcpTestSucceeded : True
```

Uji penolakan, dengan sesi kedua tetap terbuka. Ganti sementara ke subnet yang
bukan milik Anda di **[Server]**:

```bash
ufw delete allow from <subnet-admin> to any port 22 proto tcp
ufw allow from 10.99.99.0/24 to any port 22 proto tcp
```

Dari **[PC Windows]**, koneksi baru harus gagal (timeout):

```powershell
Test-NetConnection <IP-VM> -Port 22               # TcpTestSucceeded : False
```

Kembalikan rule yang benar di **[Server]**:

```bash
ufw delete allow from 10.99.99.0/24 to any port 22 proto tcp
ufw allow from <subnet-admin> to any port 22 proto tcp
```

Rollback:

```bash
ufw allow 22/tcp
ufw delete allow from <subnet-admin> to any port 22 proto tcp
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| SSH putus setelah `ufw delete` | `<subnet-admin>` salah ketik | console Proxmox, jalankan rollback |
| `ufw delete allow 22/tcp` bilang `Could not delete non-existent rule` | rule lama bernama lain (mis. `OpenSSH`) | `ufw status numbered`, `ufw delete <nomor>` |
| Rule ada tapi akses dari luar tetap lolos | ada rule `22` lain yang lebih longgar | `ufw status numbered`, hapus yang longgar |

Jebakan:
- Hapus rule lama hanya setelah rule baru terbukti dari sesi baru.
- Dua lapis (UFW dan `AllowUsers ...@subnet`) memang disengaja. Satu lapis
  gagal, lapis lain tetap menahan.
- Sesi yang sudah terbuka tetap hidup setelah rule berubah. Karena itu uji
  selalu dari koneksi baru.

### 1.5.3 Batasi key dan sudo

Hasil: key hanya berlaku dari subnet admin, dan grup `webops` hanya bisa
menjalankan tiga perintah Nginx lewat sudo.

Prasyarat: root, satu user biasa untuk diuji (`<user>`), sesi kedua terbuka.

**Batasi key.** Tambahkan opsi di depan public key. `restrict` mematikan
forwarding, pty, dan agent untuk key itu, `pty` menyalakan lagi pty supaya
shell interaktif tetap jalan.

File: `/home/<user>/.ssh/authorized_keys`

```text
from="<subnet-admin>",restrict,pty ssh-ed25519 AAAA...isi-public-key-Anda... <user>@laptop
```

Uji dari **[PC Windows]** dalam sesi baru: login harus tetap berhasil. Kalau
ditolak, IP PC tidak masuk `<subnet-admin>`, kembalikan barisnya dari sesi
kedua.

**Sudo dengan perintah terbatas.** `visudo -f` membuka editor lalu memeriksa
sintaks sebelum menyimpan.

**[Server]**:

```bash
groupadd -f webops
usermod -aG webops <user>
visudo -f /etc/sudoers.d/webops
```

File: `/etc/sudoers.d/webops`

```text
%webops ALL=(root) /usr/bin/systemctl reload nginx, /usr/bin/systemctl restart nginx, /usr/sbin/nginx -t
```

Kalau `visudo` menampilkan `What now?`, tekan `e` untuk mengedit ulang. Jangan
simpan file yang error. Setelah tersimpan:

```bash
chmod 440 /etc/sudoers.d/webops
```

Verifikasi:

```bash
sudo -l -U <user>                          # daftar perintah yang diizinkan
su - <user> -c 'sudo nginx -t'             # jalan
su - <user> -c 'sudo cat /etc/shadow'      # ditolak
```

Rollback:

```bash
rm /etc/sudoers.d/webops
```

Error umum:

| Gejala | Sebab | Solusi |
|---|---|---|
| `visudo` error `syntax error` | salah tulis rule | tekan `e`, perbaiki, simpan ulang |
| `sudo` abaikan file drop-in | nama file memuat titik, atau mode file terlalu longgar | nama tanpa titik, `chmod 440` |
| Key dengan `from=` ditolak dari PC admin | IP asal beda dari `<subnet-admin>` | cek `journalctl -u ssh`, sesuaikan subnet |
| Login berhasil tapi tanpa prompt shell | `restrict` tanpa `pty` | tambahkan `,pty` |

Jebakan:
- Jangan edit `/etc/sudoers` langsung. Salah satu karakter bisa mematikan sudo
  untuk semua user. Pakai drop-in dan `visudo -f`.
- `sudo` tidak boleh dibatasi ke perintah yang bisa membuka shell (`vim`,
  `less`, `find`, `systemctl edit`). Itu sama dengan akses root penuh.
- Pakai path absolut di rule sudo. Tanpa itu, rule bisa dikelabui lewat `PATH`.
