# Diagrams — warlockrpi4 Tor Relay

Dark background, neon color scheme. Source `.dot` files alongside each PNG.

| # | File | Description |
|---|------|-------------|
| 1 | [01_network_topology.png](01_network_topology.png) | Full LAN/WAN topology — ARRIS NAT, IPv4 vs IPv6 paths, UFW, rpi4 ports |
| 2 | [02_tor_service_arch.png](02_tor_service_arch.png) | Tor service architecture — systemd units, ports, keys, monitoring tools |
| 3 | [03_boot_sequence.png](03_boot_sequence.png) | Boot sequence — fake-hwclock → ntpsec → time-sync.target → tor@default → verify |
| 4 | [04_verify_flow.png](04_verify_flow.png) | `tor-relay-verify` script logic — IP check, port probe, control port, onionoo |

Regenerate any diagram:
```bash
dot -Tpng -Gdpi=150 01_network_topology.dot -o 01_network_topology.png
```
