#!/bin/bash
set -u
echo "=== sebelum restart ==="
curl -sk -o /dev/null -D- https://hello.lab.test/ | grep -i x-cache-status
echo "=== restart nginx (cache harus bertahan) ==="
systemctl restart nginx; sleep 2; systemctl is-active nginx
curl -sk -o /dev/null -D- https://hello.lab.test/ | grep -i x-cache-status
echo "=== tunggu 11 detik (TTL 10s) ==="
sleep 11
curl -sk -o /dev/null -D- https://hello.lab.test/ | grep -i x-cache-status
echo "=== request kedua langsung sesudahnya ==="
curl -sk -o /dev/null -D- https://hello.lab.test/ | grep -i x-cache-status
echo DONE
