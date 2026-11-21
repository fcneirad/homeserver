#!/usr/bin/env bash
# update.sh — bring the homeserver up to date (security + features).
# Run as root:  sudo bash update.sh [--yes | --report]
#
# Two-tier model:
#   SECURITY of OS packages (caddy, fail2ban, jellyfin, qbittorrent-nox and all
#   system libraries) is applied AUTOMATICALLY by unattended-upgrades (security
#   pocket, daily — see /var/log/unattended-upgrades/). This script does not
#   duplicate that; it only offers apt upgrades for NEW FEATURES.
#   This script covers what the OS cannot reach:
#     1. apt feature upgrades (caddy/jellyfin/... newer versions) — prompted
#     2. Authelia binary (pinned in gateway/setup.sh, GitHub releases)
#     3. Django web-app python deps (web/requirements.txt)
#   and REPORTS the self-updating apps (*arrs, seerr, bazarr, pihole), which
#   manage their own updates — do not double-manage them here.
# After any applied change it re-runs gateway/setup.sh (config re-apply + the
# 11-hostname health check).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

# This script lives at the repo root (unlike gateway/setup.sh, which is one
# level down), so no "/.." here.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSUME_YES=0
REPORT_ONLY=0
case "${1:-}" in
  --yes)    ASSUME_YES=1 ;;
  --report) REPORT_ONLY=1 ;;
  "")       ;;
  *) echo "usage: sudo bash update.sh [--yes | --report]" >&2; exit 1 ;;
esac

ask() {  # ask "prompt" -> returns 0 for yes, 1 for no
  local ans
  [ "$REPORT_ONLY" = 1 ] && return 1
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  read -r -p "$1 [y/N] " ans </dev/tty \
    || { echo "(no tty available — re-run with --yes to apply, or --report to only show status)" >&2; exit 1; }
  [[ "$ans" =~ ^[Yy] ]]
}

echo "==> homeserver update check ($(date '+%Y-%m-%d %H:%M'))${REPORT_ONLY:+  [report only]}"
CHANGED=0

# --- 1. OS packages (apt) ----------------------------------------------
# Security updates: automatic via unattended-upgrades. Here we only offer
# feature upgrades for apt-managed apps (caddy, jellyfin, qbittorrent-nox, ...).
echo
echo "--- OS packages (apt)"
apt-get update -qq
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c 'upgradable' || true)
if [ "${UPGRADABLE:-0}" -gt 0 ]; then
  echo "    $UPGRADABLE package(s) upgradable (features; security is already auto-applied):"
  apt list --upgradable 2>/dev/null | grep 'upgradable' | sed 's/^/      /' | head -15
  [ "$UPGRADABLE" -gt 15 ] && echo "      ... and $((UPGRADABLE - 15)) more"
  if ask "    Upgrade apt packages now?"; then
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    CHANGED=1
  fi
else
  echo "    up to date (security updates are applied automatically by unattended-upgrades)"
fi

# --- 2. Authelia (pinned binary, GitHub releases) ------------------------
echo
echo "--- Authelia (login gate)"
INSTALLED=$(/usr/bin/authelia --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
LATEST=$(curl -fsSL --max-time 10 \
  https://api.github.com/repos/authelia/authelia/releases/latest 2>/dev/null \
  | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed 's/.*"\(v[0-9.]*\)".*/\1/' || echo "")
if [ -z "$LATEST" ]; then
  echo "    installed: $INSTALLED (could not reach GitHub — skipping latest check)"
elif [ "$INSTALLED" = "$LATEST" ]; then
  echo "    up to date ($INSTALLED)"
else
  echo "    installed: $INSTALLED   latest: $LATEST"
  if ask "    Update Authelia to $LATEST? (bumps AUTH_VER in gateway/setup.sh, re-downloads binary)"; then
    sed -i "s|^AUTH_VER=.*|AUTH_VER=\"$LATEST\"|" "$REPO_DIR/gateway/setup.sh"
    rm -f /usr/bin/authelia   # setup.sh only downloads when the binary is missing
    CHANGED=1
  fi
fi

# --- 3. Django web app (python deps) -------------------------------------
echo
echo "--- Django homepage (python deps)"
PYBIN=$(systemctl cat homeserver 2>/dev/null | sed -n 's/^ExecStart=//p' | awk '{print $1}')
if [ -z "${PYBIN:-}" ] || [ ! -x "$PYBIN" ]; then
  echo "    (could not determine python from homeserver.service — skipping)"
else
  OUTDATED=$("$PYBIN" -m pip list --outdated 2>/dev/null \
    | awk 'NR>2 {print $1}' | grep -E '^(django|asgiref|sqlparse)$' || true)
  if [ -z "$OUTDATED" ]; then
    echo "    up to date ($("$PYBIN" -c 'import django; print("django " + django.get_version())' 2>/dev/null))"
  else
    echo "    outdated: $(echo "$OUTDATED" | tr '\n' ' ')"
    if ask "    Upgrade web-app python deps (pip install -U -r web/requirements.txt)?"; then
      "$PYBIN" -m pip install -U -r "$REPO_DIR/web/requirements.txt"
      CHANGED=1
    fi
  fi
fi

# --- 4. Self-updating apps (report only) ----------------------------------
echo
echo "--- Self-updating apps (managed by their own updaters — report only)"
# *arr binaries are capitalized (Radarr/Sonarr/Prowlarr) inside lowercase dirs.
declare -A ARR_BIN=( [radarr]=Radarr [sonarr]=Sonarr [prowlarr]=Prowlarr )
for app in radarr sonarr prowlarr; do
  v=$("$REPO_DIR/$app/${ARR_BIN[$app]}" --version 2>/dev/null | grep -oE 'Version [0-9.]+' | awk '{print $2}' || true)
  printf '    %-10s %s\n' "$app:" "${v:-?}"
done
printf '    %-10s %s\n' "bazarr:" "$(cat "$REPO_DIR/bazarr/VERSION" 2>/dev/null | tr -d '[:space:]')"
printf '    %-10s %s\n' "seerr:" "$(grep -m1 '"version"' "$REPO_DIR/seerr/package.json" 2>/dev/null | sed 's/.*"\([0-9][^"]*\)".*/\1/')"
printf '    %-10s %s\n' "pihole:" "$(pihole -v 2>/dev/null | head -1 | sed 's/^Core version is //')"

# --- Finalize --------------------------------------------------------------
echo
if [ "$CHANGED" = 1 ]; then
  echo "==> changes applied — re-applying config + health check (gateway/setup.sh)"
  bash "$REPO_DIR/gateway/setup.sh"
else
  echo "==> nothing changed."
fi
echo "Tip: *arrs/seerr/bazarr update from their own UIs; pihole: sudo pihole -up"
