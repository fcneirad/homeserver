#!/usr/bin/env bash
# wsl2-setup.sh — make a Pi-hole v6 install work on WSL2 (mirrored mode)
# Run AFTER the official installer has completed. Idempotent.
#
# Target design ("option 2"): FTL listens on port 1053, NOT :53. In mirrored
# mode Windows consumes inbound UDP/53 to the host IP, so a Windows-side relay
# (dns-relay.ps1 + dns-relay-tcp.ps1) binds :53 and forwards to TCP/1053.
# The web UI moves to HTTPS 8443 because 80/443 belong to the Django homepage.
#
# Why FTL needs manual config:
#  - WSL2 keeps its own DNS listeners on 127.0.0.53/.54:53 and 10.255.255.254:53,
#    so FTL's default wildcard :53 bind fails with "Address in use".
#  - BIND mode is NOT enough: FTL still auto-binds loopback (10.255.255.254),
#    which also fails and kills the DNS engine (CRIT in FTL.log) even though
#    the LAN socket bound fine.
#  - Fix: dns.listeningMode="NONE" (FTL emits no listening directives) +
#    explicit dnsmasq lines binding ONLY the LAN IP.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

# Detect the LAN IP. The vNIC NAME is NOT stable across WSL restarts
# (eth4 -> eth5 ...), so detect by IP instead. This design requires MIRRORED
# mode (WSL shares the host's 192.168.x.x LAN IP); NAT mode was tried and
# rejected — see diagnostics/README.md.
LAN_IP4=$(ip -4 -o addr show | awk '$4 ~ /^192\.168\./ {print $4}' | head -1 | cut -d/ -f1)
[ -n "$LAN_IP4" ] || { echo "ERROR: no 192.168.x.x address found — this design requires WSL2 MIRRORED mode (check %USERPROFILE%\\.wslconfig, then wsl --shutdown)"; exit 1; }
LAN_IFACE=$(ip -4 -o addr show | awk -v ip="${LAN_IP4}/" '$4 ~ "^"ip {print $2}' | head -1)
echo "Detected mirrored mode: IP=${LAN_IP4} on ${LAN_IFACE}"

# dnsmasq listen directives. local-service is correct in mirrored mode because
# all real clients are on the same LAN subnet as the host IP.
DNSMASQ_LINES="[ \"listen-address=${LAN_IP4}\", \"bind-interfaces\", \"local-service\" ]"

# Remove stale v5-era listen file (v6 ignores /etc/dnsmasq.d by default)
rm -f /etc/dnsmasq.d/02-pihole-listen.conf

# IMPORTANT: stop FTL before editing pihole.toml. FTL rewrites the config on a
# clean shutdown, which would revert any edits made while it is running.
systemctl stop pihole-FTL
sleep 1

# --- 1. Restrict FTL's DNS bind to the LAN IP only --------------------------
# listeningMode=NONE: FTL emits no listening directives at all. (BIND mode is
# not enough — it still auto-binds loopback, which WSL holds -> CRIT kills the
# DNS engine even though the LAN socket bound fine.)
if grep -qE '^\s*listeningMode' /etc/pihole/pihole.toml; then
  sed -i -E "s|^\s*listeningMode\s*=.*|listeningMode = \"NONE\"|" /etc/pihole/pihole.toml
else
  sed -i '/^\[dns\]/a\\n  listeningMode = "NONE"' /etc/pihole/pihole.toml
fi
# Explicit dnsmasq lines: bind ONLY the LAN IP. bind-interfaces prevents a
# wildcard socket (which would collide with WSL's own :53 listeners);
# local-service keeps the safe default of answering only local-subnet clients.
if grep -qE '^\s*dnsmasq_lines' /etc/pihole/pihole.toml; then
  sed -i -E "s|^\s*dnsmasq_lines\s*=.*|dnsmasq_lines = ${DNSMASQ_LINES}|" /etc/pihole/pihole.toml
else
  sed -i "/^\[misc\]/a\\n  dnsmasq_lines = ${DNSMASQ_LINES}" /etc/pihole/pihole.toml
fi
# Upstream DNS — required for any non-local resolution (empty = nothing resolves)
if grep -qE '^\s*upstreams' /etc/pihole/pihole.toml; then
  sed -i -E "s|^\s*upstreams\s*=.*|upstreams = [ \"1.1.1.1\", \"9.9.9.9\" ]|" /etc/pihole/pihole.toml
else
  sed -i '/^\[dns\]/a\\n  upstreams = [ "1.1.1.1", "9.9.9.9" ]' /etc/pihole/pihole.toml
fi

# --- 2. DNS server port: 1053 (NOT 53 — Windows owns :53 in mirrored mode;
#     the Windows-side relay forwards LAN :53 -> TCP/1053) -------------------
if grep -qE '^\s*port = 1053' /etc/pihole/pihole.toml; then
  echo "dns.port already 1053"
elif grep -qE '^\s*port = 53\s*$' /etc/pihole/pihole.toml; then
  sed -i -E 's|^\s*port = 53\s*$|port = 1053|' /etc/pihole/pihole.toml
else
  echo "WARNING: dns port line not found — set it to 1053 in the Web UI"
fi

# --- 3. Web server port: 8443 (80/443 belong to the Django homepage) --------
if grep -qE '^\s*port = "8443os' /etc/pihole/pihole.toml; then
  echo "webserver.port already 8443"
else
  sed -i -E 's|^\s*port = "80o,443os,\[::\]:80o,\[::\]:443os"|port = "8443os,[::]:8443os"|' /etc/pihole/pihole.toml
  grep -qE '^\s*port = "8443os' /etc/pihole/pihole.toml || \
    echo "WARNING: webserver port was not the default — verify it is 8443"
fi

# --- 4. Start FTL and verify -------------------------------------------------
systemctl start pihole-FTL
sleep 4

echo
echo "=== Post-setup check ==="
systemctl is-active pihole-FTL
if ss -ulnp | awk '{print $4}' | grep -qE "^${LAN_IP4}:1053$"; then
  echo "DNS bound to ${LAN_IP4}:1053 OK"
else
  echo "WARNING: not bound to ${LAN_IP4}:1053 — check /var/log/pihole/FTL.log"
fi
# A bind CRIT can leave FTL "active" while the DNS engine is dead — check log
if tail -n 100 /var/log/pihole/FTL.log | grep -qE 'CRIT.*listening socket'; then
  echo "ERROR: FTL.log shows a listening-socket CRIT — DNS engine is NOT running:"
  tail -n 100 /var/log/pihole/FTL.log | grep -E 'CRIT|listening on' | tail -5
fi
if grep -q "10.255.255.254" /etc/resolv.conf; then
  echo "resolv.conf untouched (still WSL-managed) OK"
else
  echo "WARNING: /etc/resolv.conf was modified — inspect it"
fi

echo
echo "Web UI : https://${LAN_IP4}:8443/admin/  (self-signed cert)"
echo "Relay  : start dns-relay.ps1 on Windows (see README) — FTL alone does NOT serve :53"
echo "Verify : ./check_health.sh"
