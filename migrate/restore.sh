#!/usr/bin/env bash
# ============================================================================
# migrate/restore.sh — restore a homeserver backup on the NEW box.
#
# Usage (on the new server, as root):
#   sudo bash migrate/restore.sh /path/to/homeserver-backup-YYYYMMDD-HHMMSS.tar.zst
#
# What it does:
#   1. Verifies the archive checksum (if a .sha256 sits next to it).
#   2. Extracts to a staging dir and shows you the manifest + what will be
#      overwritten, then asks for confirmation.
#   3. Restores in dependency order:
#        /var/lib/*  service state (jellyfin, *arrs, bazarr, qbittorrent,
#                    authelia incl. users+TOTP, caddy certs, fail2ban)
#        /etc/*      configs + custom systemd units
#        repo-local  .env, web/db.sqlite3, seerr/config (into the repo clone)
#        app dirs    radarr/ sonarr/ prowlarr/ seerr/ bazarr/ flaresolverr/
#                    (only if not already present — re-running each service's
#                     setup script is the alternative)
#        unsloth     ~/.unsloth/studio (model cache NOT included; it will be
#                    re-downloaded on first use) + ~/.local/share/unsloth
#        media/*     only if the archive contains a media/ section
#   4. Fixes ownership to match the running box's users, runs
#      `systemctl daemon-reload`, and prints the remaining manual steps.
#
# IMPORTANT — do this BEFORE first starting services on the new box:
#   a. Clone the repo (git clone) and run each service's setup script so all
#      binaries/users/units exist (see docs/services.md). The restore then
#      layers your state on top of the fresh install.
#   b. If the new box has a different LAN IP or public IP: update .env
#      (DDNS_HOST stays the same if DNS points at the new IP), re-render
#      Caddyfile + Authelia config via `sudo bash gateway/setup.sh`, and
#      update any hardcoded IPs in /etc/pihole (lighttpd.conf) + router.
#   c. Pi-hole: on native Linux FTL binds :53 directly — the Windows relay
#      scripts do NOT apply. Point the router's DHCP DNS at the new box.
# ============================================================================
set -euo pipefail

log() { printf '[restore] %s\n' "$*"; }
die() { printf '[restore] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root: sudo bash migrate/restore.sh <archive>"
[ $# -ge 1 ] || die "usage: sudo bash migrate/restore.sh /path/to/homeserver-backup-*.tar.zst"
ARCHIVE="$1"
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"

# --- 1. checksum -------------------------------------------------------------
if [ -f "$ARCHIVE.sha256" ]; then
  log "verifying checksum..."
  ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" ) \
    || die "checksum mismatch — archive is corrupt, aborting"
else
  log "WARN: no .sha256 next to archive; skipping checksum verification"
fi

# --- 2. stage + preview -------------------------------------------------------
STAGE="$(mktemp -d /tmp/restore-XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

log "extracting to staging dir $STAGE ..."
tar --zstd -xf "$ARCHIVE" -C "$STAGE"

if [ -f "$STAGE/manifest.txt" ]; then
  echo; cat "$STAGE/manifest.txt"; echo
fi

# What will be overwritten on this box? (only the paths restore actually replaces)
echo "Paths that ALREADY EXIST here and would be replaced:"
EXISTING=0
for p in var/lib/jellyfin var/lib/radarr var/lib/sonarr var/lib/prowlarr \
         var/lib/bazarr var/lib/qbittorrent var/lib/authelia var/lib/caddy \
         var/lib/fail2ban etc/caddy etc/authelia etc/fail2ban etc/jellyfin \
         etc/pihole etc/default/jellyfin; do
  if [ -e "$STAGE/$p" ] && [ -e "/$p" ]; then
    echo "  /$p"
    EXISTING=1
  fi
done
[ "$EXISTING" = 0 ] && echo "  (none)"
echo

read -r -p "Proceed with restore? [y/N] " ans
[ "${ans:-}" = "y" ] || [ "${ans:-}" = "Y" ] || die "aborted by user"

# --- 3. restore ---------------------------------------------------------------
restore_path() {
  local rel="$1" src="$STAGE/$1" dst="/$1"
  if [ -e "$dst" ]; then
    log "replacing existing: $dst"
    rm -rf "$dst"
  fi
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  log "restored: $dst"
}

log "restoring /var/lib service state..."
for d in jellyfin radarr sonarr prowlarr bazarr qbittorrent authelia caddy fail2ban; do
  [ -d "$STAGE/var/lib/$d" ] && restore_path "var/lib/$d"
done

log "restoring /etc configs + units..."
for d in caddy authelia fail2ban jellyfin pihole; do
  [ -d "$STAGE/etc/$d" ] && restore_path "etc/$d"
done
[ -f "$STAGE/etc/default/jellyfin" ] && restore_path "etc/default/jellyfin"
for u in authelia bazarr homeserver pihole-FTL prowlarr qbittorrent-nox \
         radarr seerr sonarr unsloth; do
  [ -f "$STAGE/etc/systemd/system/$u.service" ] \
    && restore_path "etc/systemd/system/$u.service"
done
[ -d "$STAGE/etc/systemd/system/jellyfin.service.d" ] \
  && restore_path "etc/systemd/system/jellyfin.service.d"

log "restoring repo-local state..."
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The backup staged paths under home/<user>/software/homeserver — locate the
# staged repo dir (works for any source username).
SRC_HOME_STAGE="$(find "$STAGE/home" -maxdepth 4 -name .env -path '*/software/homeserver/.env' 2>/dev/null | head -1 | sed 's|/\.env$||')"
if [ -z "$SRC_HOME_STAGE" ]; then
  log "WARN: no repo-local state found in archive (expected home/<user>/software/homeserver/.env)"
else
  if [ -f "$SRC_HOME_STAGE/.env" ]; then
    cp -a "$SRC_HOME_STAGE/.env" "$REPO_DIR/.env"
    log "restored: $REPO_DIR/.env"
  fi
  if [ -f "$SRC_HOME_STAGE/web/db.sqlite3" ]; then
    cp -a "$SRC_HOME_STAGE/web/db.sqlite3" "$REPO_DIR/web/db.sqlite3"
    log "restored: $REPO_DIR/web/db.sqlite3"
  fi
  if [ -d "$SRC_HOME_STAGE/seerr/config" ]; then
    mkdir -p "$REPO_DIR/seerr"
    cp -a "$SRC_HOME_STAGE/seerr/config" "$REPO_DIR/seerr/"
    log "restored: $REPO_DIR/seerr/config"
  fi
fi

log "restoring app install dirs (skipping any already present)..."
for d in radarr sonarr prowlarr seerr bazarr flaresolverr; do
  if [ -n "${SRC_HOME_STAGE:-}" ] && [ -d "$SRC_HOME_STAGE/$d" ]; then
    if [ -d "$REPO_DIR/$d" ]; then
      log "skip (already present): $REPO_DIR/$d — re-run its setup script if versions differ"
    else
      cp -a "$SRC_HOME_STAGE/$d" "$REPO_DIR/$d"
      log "restored: $REPO_DIR/$d"
    fi
  fi
done

log "restoring unsloth state (model cache will re-download on first use)..."
# Target home = the user that owns this repo clone.
TARGET_HOME="$(dirname "$(dirname "$REPO_DIR")")"
SRC_USER_HOME_STAGE="$(dirname "$(dirname "$SRC_HOME_STAGE")")"   # .../home/<user>
if [ -n "${SRC_HOME_STAGE:-}" ] && [ -d "$SRC_USER_HOME_STAGE/.unsloth/studio" ]; then
  mkdir -p "$TARGET_HOME/.unsloth"
  cp -a "$SRC_USER_HOME_STAGE/.unsloth/studio" "$TARGET_HOME/.unsloth/"
  log "restored: $TARGET_HOME/.unsloth/studio"
fi
if [ -n "${SRC_HOME_STAGE:-}" ] && [ -d "$SRC_USER_HOME_STAGE/.local/share/unsloth" ]; then
  mkdir -p "$TARGET_HOME/.local/share"
  cp -a "$SRC_USER_HOME_STAGE/.local/share/unsloth" "$TARGET_HOME/.local/share/"
  log "restored: $TARGET_HOME/.local/share/unsloth"
fi

if [ -d "$STAGE/media" ]; then
  log "archive contains media/ — restore it manually to the right mount point:"
  ls -1 "$STAGE/media" | sed 's/^/  media\//; s/$/ -> (choose target dir)/'
fi

# --- 4. ownership + daemon reload ---------------------------------------------
log "fixing ownership..."
chown -R jellyfin:jellyfin   /var/lib/jellyfin   2>/dev/null || true
chown -R radarr:radarr       /var/lib/radarr     2>/dev/null || true
chown -R sonarr:sonarr       /var/lib/sonarr     2>/dev/null || true
chown -R prowlarr:prowlarr   /var/lib/prowlarr   2>/dev/null || true
chown -R bazarr:bazarr       /var/lib/bazarr     2>/dev/null || true
chown -R qbittorrent:qbittorrent /var/lib/qbittorrent 2>/dev/null || true
chown -R authelia:authelia   /var/lib/authelia /etc/authelia 2>/dev/null || true
chown -R caddy:caddy         /etc/caddy          2>/dev/null || true
chown -R pihole:pihole       /etc/pihole         2>/dev/null || true
OWNER_USER="$(stat -c %U "$REPO_DIR")"
chown -R "$OWNER_USER" "$REPO_DIR/.env" "$REPO_DIR/web/db.sqlite3" \
  "$TARGET_HOME/.unsloth" "$TARGET_HOME/.local/share/unsloth" 2>/dev/null || true

systemctl daemon-reload
log "systemd units reloaded."

cat <<'EOF'

============================================================================
Restore complete. Remaining manual steps (in order):
============================================================================
 1. If the public IP changed: update DNS (A + wildcard records) to the new
    IP, then run `sudo bash gateway/setup.sh` to re-render Caddyfile and
    Authelia config from .env. Let's Encrypt will issue fresh certs.
 2. If the LAN IP changed: update /etc/pihole/lighttpd.conf (PIHOLE_INTERFACE
    + IPs), router DHCP DNS setting, and any hardcoded IPs in .env.
 3. Start services:  systemctl start pihole-FTL caddy authelia fail2ban
                     then the app services (jellyfin radarr sonarr prowlarr
                     seerr bazarr qbittorrent-nox homeserver unsloth).
 4. Verify: open https://<your-domain>/ and log in with your Authelia
    credentials + TOTP code (your authenticator app still works — the TOTP
    secret was restored from the backup).
 5. Pi-hole on native Linux: FTL binds :53 directly. No Windows relay, no
    portproxy. Just point the router's DHCP DNS at this box.
 6. Unsloth: model cache was intentionally not backed up; models re-download
    on first use in Studio.
============================================================================
EOF
