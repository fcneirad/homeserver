#!/usr/bin/env bash
# gateway/setup.sh — Phase 1 pilot: Django homepage behind Caddy + Let's Encrypt.
# Idempotent; safe to re-run. Run as root:  sudo bash gateway/setup.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO_DIR/.env" ]; then set -a; . "$REPO_DIR/.env"; set +a; fi
: "${DDNS_HOST:?set DDNS_HOST in $REPO_DIR/.env (see .env.example)}"

echo "==> gateway pilot for https://$DDNS_HOST/"

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

# 4. Start Caddy and wait for the Let's Encrypt cert (first run takes a moment)
systemctl restart caddy
echo "==> waiting for https://$DDNS_HOST/ (LE cert issuance on first run) ..."
ok=""
code=""
for i in $(seq 1 30); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
    --resolve "$DDNS_HOST:443:127.0.0.1" "https://$DDNS_HOST/" 2>/dev/null || true)
  if [ "$code" = "200" ]; then ok=1; break; fi
  sleep 2
done
if [ -n "$ok" ]; then
  echo "OK — homepage is up at https://$DDNS_HOST/ (HTTP 200)"
else
  echo "NOT UP yet (last HTTP ${code:-ERR}). Check: journalctl -u caddy -n 30"
  echo "Common causes: router not forwarding TCP 80+443, or DDNS pointing elsewhere."
  exit 1
fi
