from urllib.parse import urlsplit

# Subdomain per service — must mirror the site blocks in gateway/Caddyfile.
# Port-based URLs (scheme://host:PORT) only work on the LAN; from outside,
# only 80/443 are forwarded, so every link must go through the gateway.
SUBDOMAINS = {
    'jellyfin': 'jellyfin',
    'qbittorrent': 'qbittorrent',
    'radarr': 'radarr',
    'sonarr': 'sonarr',
    'bazarr': 'bazarr',
    'prowlarr': 'prowlarr',
    'seerr': 'seerr',
    'unsloth': 'unsloth',
}


def service_urls(request):
    host = urlsplit(f'//{request.get_host()}').hostname

    urls = {name: f'https://{sub}.{host}/' for name, sub in SUBDOMAINS.items()}
    urls['pihole'] = f'https://pihole.{host}/admin/'
    return {'service_urls': urls}