# homeserver-infra

The blueprint + operating manual for a personal homeserver. This repo has two jobs:

1. **Explain the architecture** — what runs on the server, how the pieces fit
   together, and why. Start with [`docs/architecture.md`](docs/architecture.md).
2. **Install / update / rebuild it** — every service is brought up by an
   idempotent, parameterized script plus sanitized config templates, so the whole
   server can be reproduced from scratch or changed as reviewable diffs.

> This repo is **public**. It contains no real IPs, MACs, hostnames, usernames,
> secrets, or data — only scripts, templates, and documentation. Machine-specific
> values live in a gitignored `.env` on the actual server (see `.env.example`).

## Layout

```
├── README.md               ← you are here
├── .gitignore              ← keeps secrets/data/logs out of a public repo
├── .env.example            ← template for machine-specific values
├── docs/
│   ├── architecture.md     ← the server map: services, ports, topology, target design
│   └── services.md         ← upstream apps: versions + install commands
├── update.sh               ← security + feature update runner (see below)
├── pihole/                 ← Pi-hole DNS tracker/adblocker (fully populated example)
├── web/                    ← Django homepage / dashboard (our code)
├── gateway/                ← single-port HTTPS reverse proxy (Caddy + Let's Encrypt + Authelia)
└── migrate/                ← move-to-new-hardware tooling (backup.sh / restore.sh)
```

Upstream applications (Jellyfin, Radarr, Sonarr, Prowlarr, Seerr, Bazarr,
FlareSolverr, qBittorrent, Unsloth) are **not committed** — they are stock
installs documented in [`docs/services.md`](docs/services.md). Their live data
databases and configs stay on the server.

## Conventions

- **Parameterize everything.** Scripts read machine-specific values (IPs, paths,
  usernames, hostnames) from environment variables / `.env`. Nothing is hardcoded.
- **Device-agnostic docs.** A device is just "a device" — no names, IPs, or MACs.
- **Idempotent setup scripts.** Safe to run twice; they configure, never clobber.
- **Templates, not live files.** The repo holds `*.example` config templates with
  placeholders; an apply step copies them into place on the server.
- **Never commit:** databases (`*.db`, `*.sqlite*`), logs, CSVs (the DNS relay CSV
  is browsing history), `.env`, or anything under `/var/lib`.

## Keeping it updated (security vs features)

Updates are split into two tiers on purpose:

- **Security of OS packages is automatic.** Caddy, fail2ban, Jellyfin,
  qBittorrent and every system library get distro security patches applied by
  `unattended-upgrades` (security pocket, daily). You don't run anything for this;
  see `/var/log/unattended-upgrades/` for what it has applied.
- **Features + the non-OS surfaces are one command.** Run
  `sudo bash update.sh` to review and apply: apt feature upgrades, an Authelia
  bump (pinned in `gateway/setup.sh`), and Django web-app python deps. It then
  re-runs `gateway/setup.sh` to re-apply config and health-check all hostnames.
  The self-updating apps (*arrs, Seerr, Bazarr) and Pi-hole are **reported only** —
  they manage their own updates (their UIs / `pihole -up`).

Flags: `--report` shows status without changing anything; `--yes` applies without
prompting. Run `--report` first to see what's behind.

## Quick start (on a fresh box)

1. Copy `.env.example` → `.env` and fill in your values.
2. Run each service's setup script in dependency order (Pi-hole first, then the
   media stack, then `web/`, then `gateway/setup.sh`). See each folder's README.
3. Verify with the per-service health checks.

To move to new hardware, see `migrate/README.md` (`backup.sh` / `restore.sh`).

## Roadmap (not yet implemented)

- [ ] **Per-service `exposed` flag**: generate the Caddyfile from a config with an
      `exposed` toggle so hiding a service is one flag flip. See `gateway/README.md`.
- [ ] **Jellyfin OIDC SSO**: true single sign-on for the native app (optional).
- [ ] **Per-service folders** for the upstream apps once they get config templates.
