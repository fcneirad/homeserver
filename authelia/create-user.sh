#!/usr/bin/env bash
# authelia/create-user.sh — create or update a user in Authelia's file backend.
# The password is typed locally (never passed on the command line) and hashed
# with Authelia's own bcrypt implementation, so compatibility is guaranteed.
#
# Usage:  sudo bash authelia/create-user.sh <username> [email]
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO_DIR/.env" ] && { set -a; . "$REPO_DIR/.env"; set +a; }

USERS_FILE=/var/lib/authelia/users.yaml
USERNAME="${1:?usage: create-user.sh <username> [email]}"
EMAIL="${2:-${USERNAME}@${DDNS_HOST:-localhost}}"

read -rs -p "Password for '$USERNAME': " PASS; echo
[ -n "$PASS" ] || { echo "empty password refused" >&2; exit 1; }

HASH="$(/usr/bin/authelia crypto hash generate bcrypt --password "$PASS" --no-confirm \
  | sed -n 's/^Digest: //p')"
[ -n "$HASH" ] || { echo "hash generation failed" >&2; exit 1; }

# PyYAML is needed to merge into the user DB without clobbering other users.
python3 -c "import yaml" 2>/dev/null || {
  echo "==> installing python3-yaml (needed once)"
  apt-get install -y python3-yaml
}

python3 - "$USERS_FILE" "$USERNAME" "$EMAIL" "$HASH" <<'PYEOF'
import sys, yaml
path, username, email, password_hash = sys.argv[1:5]
try:
    with open(path) as f:
        db = yaml.safe_load(f) or {}
except FileNotFoundError:
    db = {}
users = db.setdefault("users", {})
users[username] = {
    "password": password_hash,
    "displayname": username,
    "email": email,
    "groups": ["admins"],
}
with open(path, "w") as f:
    yaml.safe_dump(db, f, default_flow_style=False, sort_keys=True)
print(f"user '{username}' written to {path}")
PYEOF

chown authelia:authelia "$USERS_FILE"
chmod 640 "$USERS_FILE"
# watch:true usually hot-reloads; restart is the safe path — but only if the
# service is already running (a fresh install starts it from setup.sh).
if systemctl is-active --quiet authelia; then
  systemctl restart authelia
fi
echo "done. On first login, Authelia will prompt for TOTP enrollment (scan the QR with your authenticator app)."
