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
# Django env (SECRET_KEY/DEBUG) comes from .env, but systemd does NOT expand
# shell quoting — the key in .env is single-quoted for bash. We already sourced
# .env above (set -a), so $DJANGO_* hold the unquoted values; render a clean
# env file for the unit instead of pointing EnvironmentFile at .env directly.
DJANGO_ENV=/etc/systemd/system/homeserver.service.d/django.env
mkdir -p /etc/systemd/system/homeserver.service.d
{
  echo "# rendered by gateway/setup.sh from $REPO_DIR/.env — do not edit"
  if [ -n "${DJANGO_SECRET_KEY:-}" ]; then
    echo "DJANGO_SECRET_KEY=$DJANGO_SECRET_KEY"
  fi
  echo "DJANGO_DEBUG=${DJANGO_DEBUG:-false}"
} > "$DJANGO_ENV"
chmod 600 "$DJANGO_ENV"
grep -q '^EnvironmentFile=' "$UNIT" || sed -i "/^Environment=/a EnvironmentFile=$DJANGO_ENV" "$UNIT"
echo "==> homeserver.service now loads DJANGO_* from $DJANGO_ENV"
systemctl daemon-reload
systemctl restart homeserver

# 3. Authelia (unified login gate) — native binary + systemd, no Docker.
#    Secrets come from .env and are rendered into the config at install time
#    (Authelia does not expand env vars in its YAML), same pattern as Caddyfile.
AUTH_VER="v4.39.28"   # pin; bump deliberately
ARCH=$(dpkg --print-architecture)   # amd64 / arm64 ...
if [ ! -x /usr/bin/authelia ]; then
  echo "==> installing authelia ${AUTH_VER}"
  rm -f /tmp/authelia /tmp/authelia.tar.gz   # drop stale partials from earlier runs
  DL="$(mktemp /tmp/authelia.XXXXXX.tar.gz)"
  curl -fsSL --retry 3 --retry-delay 2 -o "$DL" \
    "https://github.com/authelia/authelia/releases/download/${AUTH_VER}/authelia-${AUTH_VER}-linux-${ARCH}.tar.gz" \
    || { echo "authelia download failed (network?) — re-run setup.sh"; rm -f "$DL"; exit 1; }
  [ "$(stat -c%s "$DL")" -gt 1000000 ] || { echo "authelia download too small — corrupt?"; rm -f "$DL"; exit 1; }
  tar xzf "$DL" -C /tmp authelia
  install -m 755 /tmp/authelia /usr/bin/authelia
  rm -f /tmp/authelia "$DL"
fi
# Dedicated user + data dir (idempotent).
id -u authelia >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin authelia
mkdir -p /var/lib/authelia && chown authelia:authelia /var/lib/authelia
# Authelia v4 REFUSES to start with a missing or empty user DB, so the first
# user must exist before the service comes up. Bootstrap it interactively on
# first run (single-user YAML needs no parser). Add more users later with:
#   sudo bash authelia/create-user.sh <username> [email]
if ! grep -q 'password:' /var/lib/authelia/users.yaml 2>/dev/null; then
  echo "==> creating initial Authelia user (required before first start)"
  read -rp "Username: " AUTH_USER
  [ -n "$AUTH_USER" ] || { echo "username required"; exit 1; }
  read -rs -p "Password for '$AUTH_USER': " AUTH_PASS; echo
  [ -n "$AUTH_PASS" ] || { echo "password required"; exit 1; }
  HASH="$(/usr/bin/authelia crypto hash generate bcrypt --password "$AUTH_PASS" --no-confirm \
    | sed -n 's/^Digest: //p')"
  [ -n "$HASH" ] || { echo "hash generation failed"; exit 1; }
  # Quoted heredoc + token substitution: a bcrypt hash contains '$' which an
  # unquoted heredoc would mangle into variable references.
  cat > /var/lib/authelia/users.yaml <<'EOF'
users:
  __USER__:
    displayname: __USER__
    email: __USER__@__HOST__
    groups:
      - admins
    password: __HASH__
EOF
  sed -i "s|__USER__|${AUTH_USER}|g; s|__HOST__|${DDNS_HOST}|g; s|__HASH__|${HASH}|g" \
    /var/lib/authelia/users.yaml
  chown authelia:authelia /var/lib/authelia/users.yaml && chmod 640 /var/lib/authelia/users.yaml
  unset AUTH_PASS HASH
fi
# systemd unit (from the repo, so it's reviewable + versioned).
install -m 644 "$REPO_DIR/authelia/authelia.service" /etc/systemd/system/authelia.service
systemctl daemon-reload
mkdir -p /etc/authelia && chown authelia:authelia /etc/authelia && chmod 750 /etc/authelia
# Render config from template (secrets from .env).
: "${AUTHELIA_SESSION_SECRET:?set in $REPO_DIR/.env}"
: "${AUTHELIA_STORAGE_ENCRYPTION_KEY:?set in $REPO_DIR/.env}"
sed -e "s|__DDNS_HOST__|${DDNS_HOST}|g" \
    -e "s|__AUTHELIA_SESSION_SECRET__|${AUTHELIA_SESSION_SECRET}|g" \
    -e "s|__AUTHELIA_STORAGE_ENCRYPTION_KEY__|${AUTHELIA_STORAGE_ENCRYPTION_KEY}|g" \
    "$REPO_DIR/authelia/config.template.yml" > /etc/authelia/configuration.yml
chown authelia:authelia /etc/authelia/configuration.yml && chmod 640 /etc/authelia/configuration.yml
if ! /usr/bin/authelia config validate --config /etc/authelia/configuration.yml >/dev/null; then
  echo "Authelia config invalid — check .env secrets"
  exit 1
fi
systemctl reset-failed authelia 2>/dev/null || true   # clear any crash-loop rate limit
systemctl enable --now authelia
for i in $(seq 1 30); do curl -sf http://127.0.0.1:9091/api/health >/dev/null 2>&1 && break; sleep 1; done
curl -sf http://127.0.0.1:9091/api/health >/dev/null || { echo "authelia did not come up — journalctl -u authelia"; exit 1; }
echo "==> authelia up (login UI will be https://auth.$DDNS_HOST/)"

# 4. fail2ban — bans IPs after repeated failed logins at the gateway.
command -v fail2ban-client >/dev/null 2>&1 || { echo "==> installing fail2ban"; apt-get install -y fail2ban; }
cp "$REPO_DIR/authelia/fail2ban-authelia.conf" /etc/fail2ban/filter.d/authelia.conf
grep -q 'authelia' /etc/fail2ban/jail.local 2>/dev/null || cat >> /etc/fail2ban/jail.local <<'JAIL'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[authelia]
enabled = true
backend = systemd
journal_match = _SYSTEMD_UNIT=authelia.service
filter = authelia
JAIL
# `enable --now` is a NO-OP if fail2ban already runs (it does, for sshd) —
# the new jail would never be loaded. Restart so the running server picks
# up the filter + jail, and verify it actually came up healthy.
systemctl restart fail2ban
sleep 1
fail2ban-client status authelia >/dev/null || { echo "authelia jail failed to load — journalctl -u fail2ban"; exit 1; }
echo "==> fail2ban up (jails: $(fail2ban-client status | grep 'Jail list' | sed 's/.*: //'))"

# 5. Render the Caddyfile template (substitute {env.DDNS_HOST}) and validate it.
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

# 6. Start Caddy and wait for the Let's Encrypt certs (first run takes a moment)
systemctl restart caddy

# Derive the hostname list from the template (single source of truth):
# apex + every "sub.{env.DDNS_HOST}" site block.
HOSTS=("$DDNS_HOST")
while read -r sub; do HOSTS+=("$sub.$DDNS_HOST"); done < \
  <(grep -oE '^[a-z0-9-]+\.\{env\.DDNS_HOST\}' "$REPO_DIR/gateway/Caddyfile" | sed 's|\.{env\.DDNS_HOST}||')
# With the auth gate active, unauthenticated requests answer with a 302 to the
# login page — that IS "up". (The auth UI itself is in the list via its site block.)
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
