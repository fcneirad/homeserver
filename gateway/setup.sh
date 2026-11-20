#!/usr/bin/env bash
# gateway/setup.sh — single-port HTTPS gateway (Caddy + Let's Encrypt) for all
# services listed in the Caddyfile template. Idempotent; safe to re-run.
# Run as root:  sudo bash gateway/setup.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO_DIR/.env" ]; then set -a; . "$REPO_DIR/.env"; set +a; fi
: "${DDNS_HOST:?set DDNS_HOST in $REPO_DIR/.env (see .env.example)}"

echo "==> gateway for $DDNS_HOST (all services in the Caddyfile template)"

# 1. Caddy
command -v caddy >/dev/null 2>&1 || { echo "==> installing caddy"; apt-get update -qq && apt-get install -y caddy; }

# 2. Django moves to 127.0.0.1:8000 — Caddy owns :80/:443
UNIT=/etc/systemd/system/homeserver.service
if grep -q 'runserver 0\.0\.0\.0:80' "$UNIT"; then
  sed -i 's|runserver 0\.0\.0\.0:80|runserver 127.0.0.1:8000|' "$UNIT"
  echo "==> homeserver.service now binds 127.0.0.1:8000"
fi
systemctl daemon-reload
systemctl restart homeserver

# 3. Render the Caddyfile template (substitute {env.DDNS_HOST}) and validate it.
# The Caddyfile format does NOT expand env placeholders, so we render at install
# time; re-run this script after changing DDNS_HOST in .env.
rm -rf /etc/systemd/system/caddy.service.d   # drop-in from earlier revisions, unused now
systemctl daemon-reload
sed "s|{env.DDNS_HOST}|${DDNS_HOST}|g" "$REPO_DIR/gateway/Caddyfile" > /etc/caddy/Caddyfile
chmod 644 /etc/caddy/Caddyfile
if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
  echo "Caddyfile invalid — check DDNS_HOST in $REPO_DIR/.env"
  exit 1
fi

# 4. Start Caddy and wait for the Let's Encrypt certs (first run takes a moment)
systemctl restart caddy

# Derive the hostname list from the template (single source of truth):
# apex + every "sub.{env.DDNS_HOST}" site block.
HOSTS=("$DDNS_HOST")
while read -r sub; do HOSTS+=("$sub.$DDNS_HOST"); done < \
  <(grep -oE '^[a-z0-9-]+\.\{env\.DDNS_HOST\}' "$REPO_DIR/gateway/Caddyfile" | sed 's|\.{env.DDNS_HOST}||')

echo "==> waiting for LE certs + services (${#HOSTS[@]} hostnames) ..."
fail=0
for h in "${HOSTS[@]}"; do
  ok=""
  code=""
  for i in $(seq 1 45); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
      --resolve "$h:443:127.0.0.1" "https://$h/" 2>/dev/null || true)
    # 2xx/3xx/401/403 = gateway + TLS + backend all answered (login pages are fine)
    if [[ "$code" =~ ^[234] ]]; then ok=1; break; fi
    sleep 2
  done
  if [ -n "$ok" ]; then
    printf 'OK   %-45s HTTP %s\n' "https://$h/" "$code"
  else
    printf 'FAIL %-45s last HTTP %s\n' "https://$h/" "${code:-ERR}"
    fail=1
  fi
done

if [ "$fail" = 0 ]; then
  echo "All services are up behind the gateway."
else
  echo "Some services failed — check: journalctl -u caddy -n 50"
  echo "Common causes: DNS not propagated, router not forwarding TCP 80+443, service down."
  exit 1
fi
