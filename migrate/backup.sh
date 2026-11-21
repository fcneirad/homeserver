#!/usr/bin/env bash
# ============================================================================
# migrate/backup.sh — consistent snapshot of ALL homeserver state.
#
# Usage (on the running server):
#   sudo bash migrate/backup.sh                 # full backup, default settings
#   sudo bash migrate/backup.sh -o /mnt/usb     # different destination dir
#   sudo bash migrate/backup.sh -k 5            # keep last 5 archives
#   sudo bash migrate/backup.sh -m "/data/movies /data/tv"   # include media dirs
#   sudo bash migrate/backup.sh --no-stop       # do NOT stop services (test)
#
# What it captures (see manifest.txt inside the archive):
#   var/lib  : jellyfin, radarr, sonarr, prowlarr, bazarr, qbittorrent,
#              authelia (users + TOTP!), caddy (certs), fail2ban (ban state)
#   etc      : caddy, authelia, fail2ban, jellyfin, pihole (+ consistent
#              FTL.db via sqlite online backup — DNS stays up during backup),
#              /etc/default/jellyfin, all custom systemd units
#   repo     : .env (secrets!), web/db.sqlite3 (sqlite online backup),
#              seerr/config (db + settings)
#   apps     : the gitignored app install dirs under the repo (radarr/, sonarr/,
#              prowlarr/, seerr/, bazarr/ incl. venv, flaresolverr/) — included
#              for version parity; safe to skip if you re-run the setup scripts
#   unsloth  : ~/.unsloth/studio EXCLUDING cache/ (20G of re-downloadable
#              models) + ~/.local/share/unsloth
#   media    : any dirs passed via -m, stored under media/<basename>/
#
# Behavior:
#   - Stops the app services for a consistent snapshot (pihole-FTL stays up;
#     Django and Pi-hole DBs are copied with sqlite online backups). Services
#     are restarted automatically on exit, even if the backup fails.
#   - Output: <BACKUP_DIR>/homeserver-backup-<timestamp>.tar.zst + .sha256
#   - Retention: keeps the newest $KEEP archives, prunes older ones.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The repo is expected at <home>/software/homeserver; the server user's home
# is two levels up. (Adjust if you keep the repo elsewhere.)
SERVER_HOME="$(dirname "$(dirname "$REPO_DIR")")"
# Default destination: the server user's home (not /root — we run as root).
BACKUP_DIR="${BACKUP_DIR:-$SERVER_HOME/backups}"
KEEP=3
MEDIA_DIRS=""
NO_STOP=0

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o) BACKUP_DIR="$2"; shift 2 ;;
    -k) KEEP="$2"; shift 2 ;;
    -m) MEDIA_DIRS="$2"; shift 2 ;;
    --no-stop) NO_STOP=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

log() { printf '[backup] %s\n' "$*"; }
die() { printf '[backup] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root: sudo bash migrate/backup.sh"
command -v zstd    >/dev/null 2>&1 || die "zstd not found (apt install zstd)"
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found (apt install sqlite3)"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/homeserver-backup-$TS.tar.zst"
STAGE="$BACKUP_DIR/.staging-$TS"
mkdir -p "$BACKUP_DIR"
[ -e "$STAGE" ] && die "staging dir already exists: $STAGE"

# --- service stop/start (restarted on ANY exit, even failure) ---------------
SERVICES=(unsloth seerr bazarr prowlarr sonarr radarr jellyfin qbittorrent-nox \
          homeserver authelia caddy fail2ban)
STOPPED=()

stop_services() {
  [ "$NO_STOP" = 1 ] && { log "--no-stop: leaving services running"; return; }
  local s
  for s in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$s"; then
      systemctl stop "$s" && STOPPED+=("$s") && log "stopped $s" \
        || log "WARN: could not stop $s (continuing)"
    fi
  done
}

start_services() {
  local i s
  for ((i=${#STOPPED[@]}-1; i>=0; i--)); do
    s="${STOPPED[$i]}"
    systemctl start "$s" && log "restarted $s" \
      || log "WARN: failed to restart $s — check it manually!"
  done
}

on_exit() { start_services; rm -rf "$STAGE"; }
trap on_exit EXIT

# --- staging helpers ---------------------------------------------------------
# stage <abs-path> : copy one file/dir into the staging tree, preserving attrs.
stage() {
  local src="$1" rel="${1#/}"
  [ -e "$src" ] || { log "WARN: missing, skipping: $src"; return; }
  mkdir -p "$STAGE/$(dirname "$rel")"
  cp -a "$src" "$STAGE/$rel"
}

# stage_excl <abs-path> <exclude-glob>... : copy with tar excludes.
stage_excl() {
  local src="$1"; shift
  local rel="${src#/}"
  [ -e "$src" ] || { log "WARN: missing, skipping: $src"; return; }
  mkdir -p "$STAGE/$rel"
  tar -C "$src" --exclude="$1" -cf - . | tar -xf - -C "$STAGE/$rel"
}

# --- run ---------------------------------------------------------------------
log "backup started (ts=$TS, dest=$BACKUP_DIR)"
stop_services

log "staging /var/lib service state..."
for d in jellyfin radarr sonarr prowlarr bazarr qbittorrent authelia caddy fail2ban; do
  stage "/var/lib/$d"
done

log "staging /etc configs + custom units..."
for d in caddy authelia fail2ban jellyfin pihole; do
  stage "/etc/$d"
done
stage /etc/default/jellyfin
for u in authelia bazarr homeserver pihole-FTL prowlarr qbittorrent-nox \
         radarr seerr sonarr unsloth; do
  stage "/etc/systemd/system/$u.service"
done
stage /etc/systemd/system/jellyfin.service.d

# Consistent FTL DB snapshot WITHOUT stopping Pi-hole (DNS stays up).
# The dir copy above already grabbed it; this replaces it with a
# transactionally-consistent version.
if [ -f /etc/pihole/pihole-FTL.db ]; then
  sqlite3 /etc/pihole/pihole-FTL.db \
    ".backup '$STAGE/etc/pihole/pihole-FTL.db'" \
    && log "pihole-FTL.db: consistent online backup taken"
fi

log "staging repo-local state (.env, django db, seerr config)..."
stage "$REPO_DIR/.env"
mkdir -p "$STAGE/${SERVER_HOME#/}/software/homeserver/web"
sqlite3 "$REPO_DIR/web/db.sqlite3" \
  ".backup '$STAGE/${SERVER_HOME#/}/software/homeserver/web/db.sqlite3'" \
  && log "web/db.sqlite3: consistent online backup taken"
stage "$REPO_DIR/seerr/config"

log "staging app install dirs (gitignored, version-pinned)..."
for d in radarr sonarr prowlarr seerr bazarr flaresolverr; do
  stage "$REPO_DIR/$d"
done

log "staging unsloth state (excluding re-downloadable model cache)..."
stage_excl "$SERVER_HOME/.unsloth/studio" ./cache
stage "$SERVER_HOME/.local/share/unsloth"

if [ -n "$MEDIA_DIRS" ]; then
  log "staging media dirs: $MEDIA_DIRS"
  mkdir -p "$STAGE/media"
  for m in $MEDIA_DIRS; do
    [ -d "$m" ] || { log "WARN: media dir missing, skipping: $m"; continue; }
    stage_excl "$m" ./lost+found
    # rename to basename under media/ (tar already staged it at its abs path)
    mv "$STAGE/${m#/}" "$STAGE/media/$(basename "$m")"
  done
fi

# --- manifest -----------------------------------------------------------------
{
  echo "homeserver backup manifest"
  echo "created:      $(date -Is)"
  echo "hostname:     $(hostname)"
  echo "os:           $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "kernel:       $(uname -r)"
  echo "repo:         $REPO_DIR"
  echo "source_home:  $SERVER_HOME"
  echo "no_stop:      $NO_STOP"
  echo "stopped:      ${STOPPED[*]:-none}"
  echo "media_dirs:   ${MEDIA_DIRS:-none}"
  echo ""
  echo "service versions:"
  for pkg in jellyfin radarr sonarr prowlarr seerr bazarr qbittorrent-nox caddy; do
    v="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo n/a)"
    printf '  %-18s %s\n' "$pkg" "$v"
  done
  av="$(/usr/bin/authelia version 2>/dev/null | head -1 || echo n/a)"
  printf '  %-18s %s\n' "authelia" "$av"
} > "$STAGE/manifest.txt"

# --- archive ------------------------------------------------------------------
log "creating archive: $OUT"
tar -C "$STAGE" --exclude='./var/lib/qbittorrent/qBittorrent/config/ipc-socket' \
    --zstd -cf "$OUT" .
sha256sum "$OUT" > "$OUT.sha256"

SIZE="$(du -h "$OUT" | cut -f1)"
log "done: $OUT ($SIZE)"

# --- retention ----------------------------------------------------------------
mapfile -t OLD < <(ls -1t "$BACKUP_DIR"/homeserver-backup-*.tar.zst 2>/dev/null \
  | tail -n +$((KEEP + 1)))
for old in "${OLD[@]:-}"; do
  [ -n "$old" ] || continue
  rm -f "$old" "$old.sha256"
  log "pruned old archive: $(basename "$old")"
done

log "backup complete. Services restored (see lines above)."
