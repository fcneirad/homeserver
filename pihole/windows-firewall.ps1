#Requires -RunAsAdministrator
# windows-firewall.ps1 - run as Administrator in Windows PowerShell.
# WSL2 mirrored networking routes LAN traffic through the Windows Firewall,
# so Pi-hole (UDP/TCP 53) and its web UI (TCP 443) need inbound rules.
# Idempotent: creates missing rules AND repairs any with a wrong port filter.

$ErrorActionPreference = 'Stop'

# Elevation check (clear message instead of a cryptic CIM error)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent() `
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must run in an ELEVATED (Administrator) PowerShell."
    exit 1
}

# Inbound allow rules for Pi-hole. Profile=Any so they apply regardless of the
# network category (this box's profile is Public).
$rules = @(
    @{ Name = "Pi-hole DNS UDP (WSL)"; Protocol = 'UDP'; Port = 53 },
    @{ Name = "Pi-hole DNS TCP (WSL)"; Protocol = 'TCP'; Port = 53 },
    @{ Name = "Pi-hole Web UI (WSL)";  Protocol = 'TCP'; Port = 443 }
)

foreach ($r in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound `
            -Protocol $r.Protocol -LocalPort $r.Port -Action Allow -Profile Any | Out-Null
        Write-Host "created  : $($r.Name) ($($r.Protocol)/$($r.Port))"
    } else {
        # Self-heal: verify the port filter matches, fix if drifted (e.g. 8053 -> 443).
        # Port filters can only be read/set via pipeline, so repair = delete + recreate.
        $pf = $existing | Get-NetFirewallPortFilter
        if ($pf.LocalPort -ne $r.Port -or $pf.Protocol -ne $r.Protocol) {
            Remove-NetFirewallRule -Name $existing.Name
            New-NetFirewallRule -DisplayName $r.Name -Direction Inbound `
                -Protocol $r.Protocol -LocalPort $r.Port -Action Allow -Profile Any | Out-Null
            Write-Host "repaired : $($r.Name) (was $($pf.Protocol)/$($pf.LocalPort), now $($r.Protocol)/$($r.Port))"
        } else {
            Write-Host "exists   : $($r.Name)"
        }
    }
}

Write-Host ""
Get-NetFirewallRule -DisplayName "Pi-hole*" | Get-NetFirewallPortFilter | Format-Table Name, Protocol, LocalPort -AutoSize
