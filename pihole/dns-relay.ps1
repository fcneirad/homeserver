# dns-relay.ps1 - Pi-hole DNS relay for WSL2 MIRRORED mode (UDP :53 leg).
#
# Why this exists: in mirrored mode, inbound UDP/53 destined for the host IP is
# consumed by the Windows network stack (local interest in port 53) and never
# reaches Pi-hole inside WSL. This relay binds UDP :53 on Windows, forwards each
# query to Pi-hole over TCP (port 1053), and returns the answer to the client.
# It also logs "client IP + domain" per query to a CSV, which is the source of
# truth for per-device tracking (Pi-hole itself sees the host IP as client).
#
# The TCP :53 leg runs in a child process (dns-relay-tcp.ps1) because PowerShell
# 5.1 background threads cannot see this script's scope. This script supervises
# it and restarts it if it dies.
#
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File dns-relay.ps1
# Auto-start: scheduled task "Pi-hole DNS Relay" (ONLOGON).

# --- Configuration --------------------------------------------------------
# Edit the placeholders below, or set the matching environment variables.
$targetHost = ${env:PIHOLE_TARGET_HOST}   # server LAN IP (mirrored mode shares the Windows host's LAN IP)
if (-not $targetHost) { $targetHost = "192.168.1.X" }  # <- CHANGE ME: your server's LAN IP
$targetPort = 1053                        # FTL listens here (NOT 53 - Windows claims that)
$baseDir    = ${env:RELAY_DIR}            # folder for CSV + logs; default = this script's folder
if (-not $baseDir) { $baseDir = $PSScriptRoot }
$csvFile    = Join-Path $baseDir "dns-relay.csv"
$logFile    = Join-Path $baseDir "dns-relay.log"
$tcpScript  = Join-Path $baseDir "dns-relay-tcp.ps1"

function Write-Log([string]$msg) {
    try { [System.IO.File]::AppendAllText($logFile, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg`r`n") } catch {}
}

# Parse the QNAME (domain) out of a DNS message. Returns '' on failure.
function Parse-DnsName([byte[]]$msg) {
    try {
        if ($msg.Length -lt 13) { return '' }
        $i = 12
        $labels = @()
        while ($i -lt $msg.Length) {
            $len = $msg[$i]
            if ($len -eq 0) { break }
            if (($len -band 0xC0) -eq 0xC0) { break }   # compression pointer
            $labels += [System.Text.Encoding]::ASCII.GetString($msg, $i + 1, $len)
            $i += $len + 1
        }
        return ($labels -join '.')
    } catch { return '' }
}

# Forward a DNS message to Pi-hole over TCP/1053 (DNS-over-TCP framing).
# Returns the response bytes, or $null on failure.
function Forward-DnsQuery([byte[]]$data) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect($targetHost, $targetPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(3000)) { $tcp.Close(); return $null }
        $tcp.EndConnect($ar)
        $tcp.Client.ReceiveTimeout = 5000
        $stream = $tcp.GetStream()

        $len = [BitConverter]::GetBytes([uint16]$data.Length)
        [Array]::Reverse($len)                       # big-endian
        $stream.Write($len, 0, 2)
        $stream.Write($data, 0, $data.Length)
        $stream.Flush()

        $hdr = New-Object byte[] 2
        $n = 0
        while ($n -lt 2) { $n += $stream.Read($hdr, $n, 2 - $n) }
        $respLen = ($hdr[0] -shl 8) -bor $hdr[1]
        if ($respLen -gt 4096) { $tcp.Close(); return $null }

        $resp = New-Object byte[] $respLen
        $n = 0
        while ($n -lt $respLen) { $n += $stream.Read($resp, $n, $respLen - $n) }
        $tcp.Close()
        return $resp
    } catch {
        Write-Log "forward failed: $($_.Exception.Message)"
        return $null
    }
}

# Single-instance guard: the UDP bind uses SO_REUSEADDR, so a second relay
# would silently stack on top of the first (both answer :53 -> double
# forwarding + duplicate CSV rows). If another live relay holds this mutex,
# exit. The kernel releases it automatically when the owner dies.
$relayMutex = New-Object System.Threading.Mutex($false, "Global\PiholeDnsRelay")
if (-not $relayMutex.WaitOne(0)) { Write-Log "another relay instance is running - exiting"; exit 0 }

# Wait for Pi-hole to be reachable (WSL may still be starting at boot).
# Retries forever so the relay can be started at logon before WSL is up.
Write-Log "Waiting for Pi-hole at ${targetHost}:${targetPort} ..."
$up = $false
$i = 0
while (-not $up) {
    try {
        $t = New-Object System.Net.Sockets.TcpClient
        $ar = $t.BeginConnect($targetHost, $targetPort, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(3000)) { $t.EndConnect($ar); $t.Close(); $up = $true; break }
        $t.Close()
    } catch {}
    $i++
    if ($i % 12 -eq 0) { Write-Log "still waiting for Pi-hole ... (attempt $i)" }
    Start-Sleep -Seconds 5
}

# --- Launch the TCP :53 leg as a child process (supervised) ---
$tcpProc = $null
try {
    $tcpProc = Start-Process powershell.exe `
        -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$tcpScript `
        -PassThru -WindowStyle Hidden
    Write-Log "TCP leg started (PID $($tcpProc.Id))"
} catch {
    Write-Log "WARNING: could not start TCP leg: $($_.Exception.Message)"
}
$lastRestart = Get-Date

try {
    # --- UDP :53 listener ---
    $udp = $null
    while (-not $udp) {
        try {
            $u = New-Object System.Net.Sockets.UdpClient
            $u.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
            $u.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 53)))
            $udp = $u
        } catch {
            Write-Log "UDP :53 bind failed: $($_.Exception.Message) - retrying in 30s"
            Start-Sleep -Seconds 30
        }
    }

    Write-Log "Relay started: UDP+TCP :53 -> TCP ${targetHost}:${targetPort}"

    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $udp.Client.ReceiveTimeout = 1000

    $tick = 0
    while ($true) {
        $tick++
        # Supervise the TCP leg. Fast path: process exited. Slow path (every
        # ~15s): probe the port, because Process.HasExited proved unreliable
        # in PS 5.1 - a dead child must still be detected via its socket.
        # The 20s grace period avoids killing a child that is still starting.
        $needRestart = ($null -ne $tcpProc -and $tcpProc.HasExited)
        if (-not $needRestart -and ($tick % 15 -eq 0) -and
            (Get-Date).Subtract($lastRestart).TotalSeconds -gt 20) {
            $needRestart = -not [bool](netstat -ano | Select-String -Pattern '^\s*TCP\s+\S+:53\s+.*LISTENING')
        }
        if ($needRestart) {
            Write-Log "TCP leg down - restarting"
            if ($tcpProc) { Stop-Process -Id $tcpProc.Id -Force -ErrorAction SilentlyContinue }
            try {
                $tcpProc = Start-Process powershell.exe `
                    -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$tcpScript `
                    -PassThru -WindowStyle Hidden
                Write-Log "TCP leg restarted (PID $($tcpProc.Id))"
            } catch { Write-Log "TCP leg restart failed: $($_.Exception.Message)" }
            $lastRestart = Get-Date
        }

        try { $data = $udp.Receive([ref]$remote) } catch { continue }   # receive timeout
        if ($data.Length -lt 12) { continue }

        # Log the query for per-device tracking (real client IP + domain).
        $domain = Parse-DnsName $data
        try {
            [System.IO.File]::AppendAllText($csvFile, "$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),$($remote.Address),$domain`r`n")
        } catch {}

        # Forward over TCP to Pi-hole (DNS-over-TCP framing).
        $resp = Forward-DnsQuery $data
        if ($null -ne $resp) {
            try { $udp.Send($resp, $resp.Length, $remote) | Out-Null } catch {}
        }
    }
} catch {
    Write-Log "FATAL: $($_.Exception.Message)"
    exit 1
}
