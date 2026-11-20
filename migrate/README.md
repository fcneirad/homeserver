# Migration tooling — stub

> **Status: not implemented.** This folder will hold the scripts and checklist
> for moving the homeserver to new hardware (e.g. from a WSL2-on-Windows box to
> a dedicated native-Linux machine).

## Why this is mostly "just run the install scripts"

Because every service in this repo is installed by an **idempotent,
parameterized** script, rebuilding on a new box is: clone the repo → run each
service's setup script in dependency order → copy over state. The only
machine-specific values (IPs, paths, usernames) come from `.env`, so a different
box just needs a different `.env`.

## Where live state lives (what to carry over)

| Location | Contents |
|---|---|
| `/var/lib/*` | Service databases (Radarr/Sonarr/FTL.db, etc.) |
| `/etc/*` | Service configs |
| the service dirs under this tree | App binaries + any local data |

## Planned contents

- `backup.sh` — tar the three state locations above into a timestamped archive.
- `restore.sh` — on the new box: install base deps, run each service setup, untar state.
- `CHECKLIST.md` — ordered, human-readable migration steps + verification.

## Note on the WSL2 → native-Linux move

The Pi-hole Windows relay (`pihole/dns-relay*.ps1`) and `windows-firewall.ps1`
exist **only** because WSL2 mirrored mode consumes inbound :53 before it reaches
WSL. On native Linux, FTL binds :53 directly — the relay and firewall scripts
disappear entirely. DNS is the only service with a real platform fork; everything
else runs identically on native Linux.
