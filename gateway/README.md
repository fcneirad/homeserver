# Gateway (reverse proxy) — design stub

> **Status: not implemented.** This folder is a placeholder for the single-port
> HTTPS gateway. It will hold the Caddyfile template, Authelia config, and
> fail2ban rules when built (see `docs/architecture.md`, "Target architecture").

## What it will do

Put one reverse proxy in front of every service so the whole homeserver is
reachable through a **single port (443)** over **HTTPS**, with unified login.

- **Caddy** on `:443` — TLS termination + hostname routing (one subdomain per
  service). Let's Encrypt certificates are obtained and renewed automatically.
- **Authelia** in front of Caddy — one identity + TOTP MFA as an auth gate for
  every service. True SSO into Jellyfin via OIDC; other apps keep their own
  password (set to the same credential everywhere).
- **fail2ban** — rate-limit / ban brute-force attempts against exposed services.

## Why hostname routing (not sub-paths)

qBittorrent WebUI, Seerr, and Unsloth have **no base-path option** (they emit
absolute root asset URLs), so they cannot live under `/name`. One subdomain per
service sidesteps that entirely and works for 100% of the stack.

## Exposure model

The Caddyfile is **generated from a per-service config** where each service has
an `exposed` flag:

- `exposed: true` → published in public DNS, reachable from anywhere.
- `exposed: false` → resolvable only via the LAN Pi-hole, unreachable externally.

Hiding a service later is a one-line change + re-apply; LAN access never breaks.

## Ports forwarded at the router

Only **443** (all traffic) and **80** (Let's Encrypt HTTP validation only).
Port 53 is intentionally **not** forwarded — see `docs/architecture.md`.
