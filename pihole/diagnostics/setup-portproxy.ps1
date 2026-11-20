#Requires -RunAsAdministrator
# setup-portproxy.ps1 - Forward host ports to WSL (NAT mode) + firewall allow rules.
# Run as Administrator in Windows PowerShell. Idempotent: safe to re-run after each reboot.
# Usage:
#   .\setup-portproxy.ps1              # set up portproxy + firewall rules
#   .\setup-portproxy.ps1 -InstallTask # also register a logon scheduled task
param([switch]$InstallTask)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error "This script must run in an ELEVATED (Administrator) PowerShell."; exit 1 }

# Ports to forward: host port -> WSL same port.
# Proto: 'both' = TCP+UDP firewall rules, 'tcp' = TCP only.
$ports = @(
    @{ Port = 53;   Proto = 'both'; Service = 'Pi-hole DNS' },
    @{ Port = 80;   Proto = 'tcp';  Service = 'Pi-hole Web UI http' },
    @{ Port = 443;  Proto = 'tcp';  Service = 'Pi-hole Web UI https' },
    @{ Port = 8989; Proto = 'tcp';  Service = 'Sonarr' },
    @{ Port = 7878; Proto = 'tcp';  Service = 'Radarr' },
    @{ Port = 9696; Proto = 'tcp';  Service = 'Prowlarr' },
    @{ Port = 6767; Proto = 'tcp';  Service = 'Bazarr' },
    @{ Port = 8080; Proto = 'tcp';  Service = 'Seerr' },
    @{ Port = 8096; Proto = 'tcp';  Service = 'Jellyfin' }
)

# Get WSL's private IP (NAT mode). Starts WSL if it is not running.
$wslIpRaw = (wsl hostname -I 2>$null)
if (-not $wslIpRaw) { Write-Error "Could not get WSL IP. Is WSL installed and able to start?"; exit 1 }
$wslIp = ($wslIpRaw.Trim() -split '\s+')[0]
Write-Host "WSL private IP: $wslIp"

# Remove legacy Pi-hole firewall rules (superseded by the WSL Forward rules below).
Get-NetFirewallRule -DisplayName 'Pi-hole*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

# --- Portproxy rules (idempotent: delete then add) ---
foreach ($p in $ports) {
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$($p.Port) 2>$null | Out-Null
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$($p.Port) connectaddress=$wslIp connectport=$($p.Port) | Out-Null
}

# --- Firewall allow rules (idempotent: create if missing) ---
foreach ($p in $ports) {
    $protos = @('TCP')
    if ($p.Proto -eq 'both') { $protos = @('TCP', 'UDP') }
    foreach ($proto in $protos) {
        $name = "WSL Forward $($p.Port) $proto ($($p.Service))"
        $existing = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol $proto -LocalPort $p.Port -Action Allow -Profile Any | Out-Null
            Write-Host "created  : $name"
        } else {
            Write-Host "exists   : $name"
        }
    }
}

# --- Optional: logon scheduled task (re-runs this script after each reboot) ---
if ($InstallTask) {
    $scriptPath = $MyInvocation.MyCommand.Path
    schtasks /Create /F /TN "WSL PortProxy Setup" /SC ONLOGON /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" | Out-Null
    Write-Host "Scheduled task 'WSL PortProxy Setup' registered (runs at logon)."
}

Write-Host ""
Write-Host "Portproxy rules:"
netsh interface portproxy show all
