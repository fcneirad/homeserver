# One-shot test: send a real DNS query (example.com A) to FTL over TCP/1053 and show the answer.
$host_ = "192.168.1.X"   # <- CHANGE ME: your server's LAN IP
$port = 1053

# Build minimal DNS query: ID=0x1234, RD=1, QD=1, qname=example.com, type=A(1), class=IN(1)
$q = [byte[]]@(0x12,0x34, 0x01,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00)
foreach ($label in @("example","com")) {
    $q += [byte[]]@([byte]$label.Length) + [System.Text.Encoding]::ASCII.GetBytes($label)
}
$q += [byte[]]@(0x00, 0x00,0x01, 0x00,0x01)

$c = New-Object Net.Sockets.TcpClient
try { $c.Connect($host_, $port) } catch { Write-Output "CONNECT FAILED: $($_.Exception.Message)"; exit 1 }
$s = $c.GetStream()

# DNS-over-TCP: 2-byte big-endian length prefix
$len = [byte[]]@([byte]($q.Length -shr 8), [byte]($q.Length -band 0xFF))
$s.Write($len, 0, 2); $s.Write($q, 0, $q.Length); $s.Flush()

# Read 2-byte length, then the response
$hdr = New-Object byte[] 2
$n = 0; while ($n -lt 2) { $n += $s.Read($hdr, $n, 2 - $n) }
$rLen = ($hdr[0] -shl 8) -bor $hdr[1]
$resp = New-Object byte[] $rLen
$n = 0; while ($n -lt $rLen) { $n += $s.Read($resp, $n, $rLen - $n) }
$c.Close()

$idOk = ($resp[0] -eq 0x12 -and $resp[1] -eq 0x34)
$rcode = $resp[3] -band 0x0F
$ancount = ($resp[6] -shl 8) -bor $resp[7]
Write-Output ("ID match: {0} | RCODE: {1} (0=NOERROR, 3=NXDOMAIN) | answers: {2}" -f $idOk, $rcode, $ancount)

# Extract first A record IP from the answer section (skip question by walking names)
$p = 12
function Skip-Name([byte[]]$b, [ref]$pos) {
    while ($true) {
        $l = $b[$pos.Value]
        if ($l -eq 0) { $pos.Value++; break }
        if (($l -band 0xC0) -eq 0xC0) { $pos.Value += 2; break }
        $pos.Value += 1 + $l
    }
}
Skip-Name $resp ([ref]$p)
$p += 4  # qtype + qclass
for ($i = 0; $i -lt $ancount; $i++) {
    Skip-Name $resp ([ref]$p)
    $type = ($resp[$p] -shl 8) -bor $resp[$p+1]; $p += 8  # type,class,TTL,len
    if ($type -eq 1) { Write-Output ("A record: {0}.{1}.{2}.{3}" -f $resp[$p], $resp[$p+1], $resp[$p+2], $resp[$p+3]) }
    $p += [int]($resp[$p-2] -shl 8) + [int]$resp[$p-1]
}
