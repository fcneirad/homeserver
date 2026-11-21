# Migration tooling — WSL2 → native Linux (or any new box)

Scripts to move the homeserver to new hardware. The design goal is that a
migration is **one backup on the old box, one restore on the new box**, with
the repo's setup scripts doing the heavy lifting of installing software.

## Why this is mostly "just run the install scripts"

Every service in this repo is installed by an **idempotent, parameterized**
script, so rebuilding on a new box is: clone the repo → run each service's
setup script in dependency order → restore state on top. The only
machine-specific values (IPs, paths, usernames) come from `.env`, which the
backup carries over.

## The two scripts

### `backup.sh` — on the OLD box

```bash
sudo bash migrate/backup.sh                  # full backup → ~/backups/
sudo bash migrate/backup.sh -o /mnt/usb      # different destination
sudo bash migrate/backup.sh -k 5             # keep last 5 (default: 3)
sudo bash migrate/backup.sh -m "/data/movies /data/tv"   # include media dirs
```

- Stops the app services for a consistent snapshot, then **restarts them on
  exit even if the backup fails** (trap). Pi-hole FTL stays up — its DB is
  copied with a SQLite *online* backup, as is Django's `db.sqlite3`.
- Output: `homeserver-backup-<timestamp>.tar.zst` + `.sha256`, retention keeps
  the newest N.
- A `manifest.txt` inside records hostname, OS, and package versions of every
  service — useful to verify the new box matches.

**What's in the archive** (see also `manifest.txt`):

| Section | Contents |
|---|---|
| `var/lib/` | jellyfin, radarr, sonarr, prowlarr, bazarr, qbittorrent, **authelia (users + TOTP secrets!)**, caddy (LE certs), fail2ban (ban state) |
| `etc/` | caddy, authelia, fail2ban, jellyfin, pihole (+ consistent FTL.db), `/etc/default/jellyfin`, all custom systemd units |
| `home/<user>/software/homeserver/` | `.env` (secrets!), `web/db.sqlite3`, `seerr/config/` (db + settings) |
| app dirs | `radarr/ sonarr/ prowlarr/ seerr/ bazarr/ flaresolverr/` — the gitignored installs, for version parity. Skip-safe: re-running each setup script on the new box is the alternative |
| unsloth | `~/.unsloth/studio` **minus** `cache/` (20G of re-downloadable models) + `~/.local/share/unsloth` |
| `media/` | only if you passed `-m`; stored under `media/<basename>/` |

### `restore.sh` — on the NEW box

```bash
sudo bash migrate/restore.sh /path/to/homeserver-backup-YYYYMMDD-HHMMSS.tar.zst
```

Verifies the checksum, shows the manifest + exactly which existing paths will
be replaced, asks for confirmation, then restores in dependency order, fixes
ownership to the new box's service users, and runs `systemctl daemon-reload`.
It ends by printing the remaining manual steps.

## Full migration procedure (WSL2 → native Linux)

### On the old box

1. `sudo bash migrate/backup.sh` — keep the archive somewhere safe (USB,
   another machine). This is your safety net for the whole move.
2. Note anything not in the backup: media files (if you add them via `-m`,
   copy them separately — they're big), and any service you added that isn't
   in the script's lists yet.

### On the new box

1. **Base install**: a fresh Ubuntu/Debian with systemd, `git`, and a user
   whose home contains `software/homeserver` (the scripts derive paths from
   the repo location).
2. **Clone the repo** into `<home>/software/homeserver`.
3. **Create `.env`** — you can restore it from the backup, but if the LAN IP
   or public IP changed, edit `DDNS_HOST`/IP values first. Generate fresh
   secrets only if you want to (existing ones still work).
4. **Run the setup scripts in dependency order** so all binaries, users and
   units exist:
   1. Pi-hole FTL (`pihole/` — on native Linux FTL binds :53 directly; the
      Windows relay + portproxy scripts do NOT apply)
   2. `gateway/setup.sh` (Caddy + Authelia + fail2ban; renders configs from
      `.env`)
   3. each app service's setup script (`radarr/ sonarr/ prowlarr/ seerr/
      bazarr/ qbittorrent/ jellyfin/ unsloth/` — see `docs/services.md`)
5. **Restore state on top**: `sudo bash migrate/restore.sh <archive>`.
   This overwrites the fresh installs' state with yours (databases, configs,
   users, TOTP, certs).
6. **If the public IP changed**: update DNS (apex + wildcard A records) to
   the new IP *before* starting Caddy, so Let's Encrypt can issue fresh
   certs. Re-run `sudo bash gateway/setup.sh` after `.env` edits.
7. **If the LAN IP changed**: update `/etc/pihole/lighttpd.conf`, the router's
   DHCP DNS setting, and any hardcoded IPs in `.env`.
8. **Start everything** (the restore script prints the exact order) and verify:
   - `https://<domain>/` homepage loads
   - log in at `https://auth.<domain>/` with your password + TOTP code —
     your existing authenticator app works, the TOTP secret was restored
   - each service subdomain responds
   - Pi-hole: browse something on a LAN device and check it's tracked

### What does NOT need migrating

- **Windows relay** (`pihole/dns-relay*.ps1`, `windows-firewall.ps1`): WSL2-only
  workarounds. On native Linux FTL binds :53 directly — they disappear.
- **Unsloth model cache** (20G): re-downloads on first use in Studio.
- **Media files**: copy separately (rsync over the LAN is fine).
- **Router config**: port forwards (TCP 80 + 443 only) point at the new IP;
  DDNS/DNS records update to the new IP.

## Testing without touching services

`sudo bash migrate/backup.sh --no-stop` runs the full staging + archive path
while leaving everything running — good for a first dry run. The resulting
archive is usable, but databases may be mid-write; use a normal (stopping)
backup as your migration snapshot.
