#!/bin/bash
set -u
echo "=== [1] useradd --system untuk service ==="
id appsvc 2>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin appsvc
id appsvc
getent passwd appsvc
echo "=== [2] nc tersedia? ==="
which nc ncat netcat 2>&1; command -v nc >/dev/null || apt-get install -y netcat-openbsd 2>&1 | tail -2
nc -z -w3 127.0.0.1 22 && echo "22 terbuka (nc bekerja)"
nc -z -w3 127.0.0.1 8081 && echo "8081 terbuka"
echo "=== [3] apakah nginx membuat sendiri direktori cache? ==="
ls -ld /var/cache/nginx/site 2>&1
echo "=== [4] uninstaller netdata ==="
ls -l /usr/libexec/netdata/netdata-uninstaller.sh 2>&1
echo "=== [5] vac dari SRC#/ ==="
SRC=/srv/data; echo "tar czf /tmp/x.tar.gz -C / ${SRC#/}"
tar czf /tmp/x.tar.gz -C / ${SRC#/} && tar tzf /tmp/x.tar.gz
echo "=== [6] journalctl pipa wc ==="
journalctl -p err -b --no-pager | wc -l
echo DONE
