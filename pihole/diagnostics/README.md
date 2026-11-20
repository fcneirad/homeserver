# Diagnostics & historical scripts

These were used during the Pi-hole-on-WSL2 bring-up (Nov 2026) to root-cause why
LAN DNS never reached WSL, and to validate each piece of the final design. They are
**not needed for day-to-day operation** — kept here for reference so the reasoning
behind the architecture is not lost.

| Script | What it did / proved | Status |
|---|---|---|
| `setup-portproxy.ps1` | Option-1 (abandoned): NAT mode + `netsh portproxy` to forward 9 ports into WSL, plus a logon scheduled task. Failed because portproxy is **TCP-only** (broke UDP/53) and it rewrites client source IPs to the NAT gateway (broke per-device tracking). | Superseded by the relay |
| `udp53-test.ps1` | 90-second UDP :53 listener on Windows. Proved Windows **can** bind :53 and receives LAN queries — Dnscache was a red herring, not the owner of the port. | One-off proof |
| `tcp1053-test.ps1` | Sends a real DNS query (example.com A) to FTL over TCP/1053 from Windows. Proved the relay's forwarding leg works end-to-end. | One-off proof |
| `check-port53-rules.ps1` | Lists enabled inbound Windows Firewall rules touching ports 53/9999 (correct `Get-NetFirewallPortFilter` pipeline syntax). | Reference |
| `windows-dnsclient-fix.ps1` | Attempted to stop/reconfigure the Dnscache service. **Dead end**: Dnscache is a protected service on Windows 11 25H2 (stop = Access denied even elevated; setting Start=4 broke host Wi-Fi). | Dead end — safe to delete |
| `undo-firewall-test.ps1` | Reverts the temporary inbound firewall rules created during testing. | One-off cleanup |

The final, working design is documented in the parent folder's `README.md`:
mirrored mode + FTL on port 1053 + a Windows-side UDP/TCP :53 relay
(`dns-relay.ps1` / `dns-relay-tcp.ps1`).
