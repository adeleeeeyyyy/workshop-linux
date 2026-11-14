#!/bin/bash
set -u
systemctl disable --now hello 2>&1 | tail -1
pkill -f 'http.server 8000' 2>/dev/null
pkill -f 'http.server 8080' 2>/dev/null
sleep 1
ss -tlnp | grep -E ':8080|:8000' || echo "8080 dan 8000 kosong"
