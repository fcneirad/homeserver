# Lists ALL enabled inbound rules whose port filter touches 53 or 9999,
# using correct pipeline syntax (Get-NetFirewallPortFilter has no -Name param).
$results = @()
$rules = Get-NetFirewallRule -Direction Inbound -Enabled True
foreach ($r in $rules) {
    $pf = $r | Get-NetFirewallPortFilter
    if (($pf.LocalPort -contains 53) -or ($pf.LocalPort -contains 9999)) {
        $results += [PSCustomObject]@{
            DisplayName = $r.DisplayName
            Action      = $r.Action
            Profile     = ($r.Profile -join ',')
            Protocol    = $pf.Protocol
            LocalPort   = ($pf.LocalPort -join ',')
        }
    }
}
if ($results.Count -eq 0) {
    Write-Host "No enabled inbound rules touch ports 53 or 9999."
} else {
    $results | Format-Table -AutoSize
}
