#!/usr/bin/env bash
# check_health.sh — quick sanity check for the Pi-hole (v6)
set -uo pipefail

# Mirrored-mode vNIC name is not stable across WSL restarts — detect by IP.
IP4=$(ip -4 -o addr show | awk '$4 ~ /^192\.168\./ {print $4}' | head -1 | cut -d/ -f1)
[ -n "$IP4" ] || { echo "ERROR: no 192.168.x.x address found"; exit 1; }
IFACE=$(ip -4 -o addr show | awk -v ip="${IP4}/" '$4 ~ "^"ip {print $2}' | head -1)
echo "LAN IPv4  : $IP4 ($IFACE)"

fail=0
state=$(systemctl is-active pihole-FTL 2>/dev/null)
printf "%-12s %s\n" "pihole-FTL:" "$state"
[ "$state" = "active" ] || fail=1

# FTL must be bound to the LAN IP on :1053 (NOT :53 — Windows owns :53 in
# mirrored mode; the Windows-side relay forwards LAN :53 -> TCP/1053).
if ss -ulnp 2>/dev/null | awk '{print $4}' | grep -qE "^${IP4}:1053$"; then
  echo "FTL bind  : OK ($IP4:1053)"
else
  echo "FTL bind  : MISSING — FTL is not listening on $IP4:1053"
  fail=1
fi

# Web UI (built into FTL in v6) on HTTPS 8443 (80/443 belong to the homepage).
# 200 = logged-in page, 302 = redirect to /admin/login — both mean the server is up.
code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://${IP4}:8443/admin/" 2>/dev/null)
echo "Web UI    : https://$IP4:8443/admin/ -> HTTP ${code:-ERR}"
[ "$code" = "200" ] || [ "$code" = "302" ] || fail=1

# End-to-end test query via UDP :53 — exercises the FULL path: Windows relay
# (:53) -> FTL (:1053). A failure here usually means the relay is not running
# on Windows, not that FTL is down. (no dig dependency)
ans=$(python3 - "$IP4" <<'EOF'
import socket, struct, sys
ip = sys.argv[1]
q = (b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00'
     b'\x07example\x03com\x00\x00\x01\x00\x01')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
try:
    s.sendto(q, (ip, 53))
    data, _ = s.recvfrom(512)
    ancount = struct.unpack('>H', data[6:8])[0]
    print("OK" if ancount > 0 else "NO_ANSWER")
except Exception as e:
    print(f"FAIL ({e})")
EOF
)
echo "Test query: $ans (example.com via $IP4)"
[ "$ans" = "OK" ] || fail=1

exit $fail
