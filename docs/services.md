# Upstream services

Stock application installs that run on the server. They are **not committed** to
this repo (no binaries, no data) — each is documented here with its role, port,
and how it is installed/updated. When a service grows custom config templates or
setup scripts, it graduates into its own top-level folder.

| Service | Port | Install / update | Notes |
|---|---|---|---|
| Jellyfin | 8096 | official install script (`get-jellyfin`) | media streaming; supports base path + OIDC (future SSO) |
| Radarr | 7878 | official binary release | movies; `UrlBase` in config.xml for base path |
| Sonarr | 8989 | official binary release | TV; `UrlBase` in config.xml for base path |
| Prowlarr | 9696 | official binary release | indexer manager for Radarr/Sonarr |
| Seerr | 5055 | official binary / Docker | request UI for Radarr/Sonarr; **no base-path option** |
| Bazarr | 6767 | pip install (venv) | subtitles for the *arrs; `base_url` setting |
| FlareSolverr | 8191 | official binary release | CAPTCHA/anti-bot proxy used by the *arrs; finds Chromium via `$PATH` |
| qBittorrent (headless) | 8080 | distro package (`qbittorrent-nox`) | downloads; **no base-path option** in webui |
| Unsloth | 8888 | local LLM studio install | has its own password auth |

## Conventions for these services

- **Version pinning:** record the exact version you run here (or in a per-service
  README once it graduates) so updates are deliberate, not accidental.
- **Config location:** live configs stay on the server (`/etc/*` or the service's
  data dir). Only *sanitized templates* belong in this repo.
- **Data:** databases and media indexes live under `/var/lib/*` — never committed.
- **Base-path support** matters for the future single-port gateway: Jellyfin,
  Radarr, Sonarr, Prowlarr, Bazarr support it; Seerr, qBittorrent, and Unsloth do
  not (which is why the gateway uses hostname routing).
