#Requires -RunAsAdministrator
# undo-firewall-test.ps1 - ONE-OFF: reverts the firewall changes made while
# debugging Pi-hole LAN access (2026-11-17).
#   - Deletes the 5 arr "(LAN)" test rules
#   - Restores the network profile to Public (its original state)
# Keeps the 3 Pi-hole rules (DNS UDP/TCP 53, Web UI TCP 443) - Pi-hole needs
# them to be reachable from LAN devices. Safe to delete this file after running.

$ErrorActionPreference = 'Stop'

foreach ($name in "Sonarr (LAN)", "Radarr (LAN)", "Prowlarr (LAN)", "Bazarr (LAN)", "Seerr (LAN)") {
    $r = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if ($r) {
        Remove-NetFirewallRule -DisplayName $name
        Write-Host "removed  : $name"
    } else {
        Write-Host "absent   : $name"
    }
}

foreach ($p in (Get-NetConnectionProfile)) {
    if ($p.NetworkCategory -eq 'Private') {
        Set-NetConnectionProfile -Name $p.Name -NetworkCategory Public
        Write-Host "profile  : $($p.Name) -> Public"
    } else {
        Write-Host "profile  : $($p.Name) already $($p.NetworkCategory)"
    }
}

Write-Host ""
Write-Host "Kept (Pi-hole needs these):"
Get-NetFirewallRule -DisplayName "Pi-hole*" | Get-NetFirewallPortFilter | Format-Table Name, Protocol, LocalPort -AutoSize
