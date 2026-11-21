# relay-watchdog.ps1 - restarts the DNS relay if its UDP :53 listener is gone.
#
# The relay (dns-relay.ps1) supervises its TCP child, but nothing supervises
# the parent: if it is killed externally (window closed, sign-out), UDP :53
# dies silently and per-device tracking stops while the orphaned TCP child
# keeps running. This watchdog detects that state and restarts everything.
#
# Run from a scheduled task every few minutes (see pihole/README.md). Register
# with stored credentials (/RU, omit /RP so schtasks prompts for the password)
# so it runs in session 0 without a console window flash, and also when nobody
# is logged on:
#   schtasks /Create /SC MINUTE /MO 5 /TN "Pi-hole DNS Relay Watchdog" `
#     /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <dir>\relay-watchdog.ps1" `
#     /RU <your-user> /RL HIGHEST /F
#
# Silent when healthy; logs only when it takes action.

$baseDir = ${env:RELAY_DIR}
if (-not $baseDir) { $baseDir = $PSScriptRoot }
$relayScript = ${env:RELAY_SCRIPT}
if (-not $relayScript) { $relayScript = Join-Path $baseDir "dns-relay.ps1" }
$logFile = Join-Path $baseDir "dns-relay-watchdog.log"

function Write-Log([string]$msg) {
    try { [System.IO.File]::AppendAllText($logFile, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg`r`n") } catch {}
}

# Is anything listening on UDP :53? (netstat line: "  UDP    0.0.0.0:53   *:*   PID")
$udpUp = [bool](netstat -ano | Select-String -Pattern '^\s*UDP\s+\S+:53\s')
if ($udpUp) { exit 0 }   # healthy - stay silent

Write-Log "UDP :53 not listening - restarting relay"

# Kill the orphaned TCP child (if any) by its port ownership. Command-line
# lookup is unreliable for detached powershell.exe, so use netstat PIDs.
# The single-instance mutex in dns-relay.ps1 guarantees no live parent exists
# when UDP :53 is down, so the only stale process can be the TCP child.
foreach ($line in (netstat -ano | Select-String -Pattern '^\s*TCP\s+\S+:53\s+.*LISTENING')) {
    $stalePid = ($line -split '\s+')[-1]
    if ($stalePid -match '^\d+$') { Stop-Process -Id $stalePid -Force -ErrorAction SilentlyContinue }
}
Start-Sleep 2

# Start a fresh relay, detached from this watchdog process.
try {
    Start-Process powershell.exe `
        -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$relayScript `
        -WindowStyle Hidden
    Write-Log "relay started"
} catch {
    Write-Log "FAILED to start relay: $($_.Exception.Message)"
}
