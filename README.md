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
├── pihole/                 ← Pi-hole DNS tracker/adblocker (fully populated example)
├── web/                    ← Django homepage / dashboard (our code)
├── gateway/                ← single-port HTTPS reverse proxy (design stub, not built yet)
└── migrate/                ← move-to-new-hardware tooling (stub, not built yet)
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

## Quick start (on a fresh box)

1. Copy `.env.example` → `.env` and fill in your values.
2. Run each service's setup script in dependency order (Pi-hole first, then the
   media stack, then `web/`). See each folder's README.
3. Verify with the per-service health checks.

The full "rebuild from zero" entrypoint (`install.sh`) and the migration tooling
are planned — see `migrate/README.md`.

## Roadmap (not yet implemented)

- [ ] **Gateway**: Caddy on :443 + Let's Encrypt + Authelia unified login,
      generated from a per-service `exposed` flag. See `gateway/README.md`.
- [ ] **Migration tooling**: `backup.sh` / `restore.sh` for moving hardware.
- [ ] **Per-service folders** for the upstream apps once they get config templates.
