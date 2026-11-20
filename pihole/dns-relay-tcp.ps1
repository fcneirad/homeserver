# dns-relay-tcp.ps1 - TCP :53 leg of the Pi-hole DNS relay (WSL2 mirrored mode).
#
# Runs as a child process of dns-relay.ps1 (which handles UDP :53). Some
# resolvers fall back to TCP when a UDP response is too large, or probe TCP
# before trusting a server - without this they may abandon the Pi-hole.
#
# Self-contained: same config as dns-relay.ps1 (keep in sync).

# --- Configuration (keep in sync with dns-relay.ps1) ----------------------
$targetHost = ${env:PIHOLE_TARGET_HOST}   # server LAN IP (mirrored mode shares the Windows host's LAN IP)
if (-not $targetHost) { $targetHost = "192.168.1.X" }  # <- CHANGE ME: your server's LAN IP
$targetPort = 1053                        # FTL listens here (NOT 53 - Windows claims that)
$baseDir    = ${env:RELAY_DIR}            # folder for CSV + logs; default = this script's folder
if (-not $baseDir) { $baseDir = $PSScriptRoot }
$csvFile    = Join-Path $baseDir "dns-relay.csv"
$logFile    = Join-Path $baseDir "dns-relay-tcp.log"

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

# Wait for Pi-hole to be reachable (WSL may still be starting at boot).
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

# Bind TCP :53 (retry forever - the UDP leg may hold resources briefly).
$listener = $null
while (-not $listener) {
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 53)
        $listener = $l
    } catch {
        Write-Log "TCP :53 bind failed: $($_.Exception.Message) - retrying in 10s"
        Start-Sleep -Seconds 10
    }
}
$listener.Start()
Write-Log "TCP :53 listener started -> TCP ${targetHost}:${targetPort}"

while ($true) {
    try { $client = $listener.AcceptTcpClient() } catch { Start-Sleep -Milliseconds 200; continue }
    try {
        $client.ReceiveTimeout = 5000
        $s = $client.GetStream()
        # DNS-over-TCP: read 2-byte length, then the query
        $hdr = New-Object byte[] 2
        $n = 0
        while ($n -lt 2) { $n += $s.Read($hdr, $n, 2 - $n) }
        $qLen = ($hdr[0] -shl 8) -bor $hdr[1]
        if ($qLen -gt 4096) { continue }
        $q = New-Object byte[] $qLen
        $n = 0
        while ($n -lt $qLen) { $n += $s.Read($q, $n, $qLen - $n) }

        # Log the query for per-device tracking (real client IP + domain).
        $ip = $client.Client.RemoteEndPoint.Address.ToString()
        $domain = Parse-DnsName $q
        try {
            [System.IO.File]::AppendAllText($csvFile, "$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),$ip,$domain`r`n")
        } catch {}

        # Forward to Pi-hole and send the answer back (length-prefixed).
        $resp = Forward-DnsQuery $q
        if ($null -ne $resp) {
            $rlen = [BitConverter]::GetBytes([uint16]$resp.Length)
            [Array]::Reverse($rlen)
            $s.Write($rlen, 0, 2)
            $s.Write($resp, 0, $resp.Length)
            $s.Flush()
        }
    } catch {
        Write-Log "tcp client failed: $($_.Exception.Message)"
    } finally {
        try { $client.Close() } catch {}
    }
}
