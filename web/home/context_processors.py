from urllib.parse import urlsplit


def service_urls(request):
    host = urlsplit(f'//{request.get_host()}').hostname

    return {
        'service_urls': {
            'jellyfin': f'{request.scheme}://{host}:8096',
            'qbittorrent': f'{request.scheme}://{host}:8080',
            'radarr': f'{request.scheme}://{host}:7878',
            'sonarr': f'{request.scheme}://{host}:8989',
            'bazarr': f'{request.scheme}://{host}:6767',
            'prowlarr': f'{request.scheme}://{host}:9696',
            'seerr': f'{request.scheme}://{host}:5055',
            'unsloth': f'{request.scheme}://{host}:8888',
            'pihole': f'https://{host}:8443/admin/',
        },
    }