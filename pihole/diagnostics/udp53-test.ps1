# udp53-test.ps1 - Diagnostic: can Windows bind UDP 53 and receive LAN queries?
# Listens on 0.0.0.0:53/UDP for 90 seconds, logs every datagram to a file.
$log = Join-Path $env:USERPROFILE "udp53-test.log"
try {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $udp.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 53)))
    "BOUND OK at $(Get-Date -Format HH:mm:ss)" | Out-File $log
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $udp.Client.ReceiveTimeout = 1000
    $end = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $end) {
        try {
            $data = $udp.Receive([ref]$ep)
            "$((Get-Date -Format HH:mm:ss)) FROM $($ep.Address):$($ep.Port) len=$($data.Length)" | Out-File $log -Append
        } catch { }
    }
    "DONE at $(Get-Date -Format HH:mm:ss)" | Out-File $log -Append
} catch {
    "BIND FAILED: $($_.Exception.Message)" | Out-File $log
}
