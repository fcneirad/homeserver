#Requires -RunAsAdministrator
# windows-dnsclient-fix.ps1 - stop (or restore) the Windows DNS Client service.
#
# WHY: Dnscache owns UDP/TCP 53 at the kernel (WFP) level - invisible to netstat.
# While it runs, any DNS query sent by a LAN device to this machine's IP on port
# 53 is intercepted by Windows and never forwarded into WSL/Pi-hole (symptom:
# nslookup <domain> <SERVER_IP> times out from other devices, Pi-hole logs
# nothing). Stopping it lets Pi-hole receive LAN DNS traffic.
# Tradeoff: Windows loses its local DNS cache (lookups go straight to the
# router/upstream - slightly slower, functionally identical). Fully reversible.
#
# Usage (ELEVATED PowerShell):
#   .\windows-dnsclient-fix.ps1          # stop + disable Dnscache (the fix)
#   .\windows-dnsclient-fix.ps1 -Revert  # restore Dnscache to Automatic + start

param([switch]$Revert)

# Elevation check - Stop-Service/Set-Service fail with a confusing error otherwise
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent() `
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must run in an ELEVATED (Administrator) PowerShell. Right-click PowerShell -> 'Run as administrator'."
    exit 1
}

$svc = 'Dnscache'

# Use sc.exe (native) instead of the .NET Stop-Service wrapper, which can fail
# with "Cannot open <svc> service on computer '.'" even when elevated.
# Note: sc syntax differs per verb:  sc stop <svc>   vs   sc config <svc> start= disabled

if ($Revert) {
    & sc.exe config $svc start= auto 2>&1 | Out-Null
    & sc.exe start $svc 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    Write-Host "REVERTED: '$svc' is back to Automatic and Running."
    Write-Host "Windows DNS caching restored. Pi-hole will no longer receive LAN UDP/53."
    return
}

$before = Get-Service $svc
Write-Host "Before: '$svc' State=$($before.Status) StartType=$($before.StartType)"

& sc.exe stop $svc 2>&1 | Out-Null
Start-Sleep -Seconds 2
& sc.exe config $svc start= disabled 2>&1 | Out-Null

$after = Get-Service $svc
Write-Host "After:  '$svc' State=$($after.Status) StartType=$($after.StartType)"
if ($after.Status -ne 'Stopped') {
    Write-Error "'$svc' is still $($after.Status). The change did not take effect."
    exit 1
}
Write-Host ""
Write-Host "DONE. Windows DNS Client stopped and disabled."
Write-Host "Now test from a LAN device:  nslookup example.com <SERVER_IP>"
Write-Host "To undo later:             .\windows-dnsclient-fix.ps1 -Revert"
