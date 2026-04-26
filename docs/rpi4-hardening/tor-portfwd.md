# Tor Relay IPv4 Port-Forward Fix

**Date:** 2026-04-26  
**Session:** `2026-04-26_020703_tor-relay-portfwd`  
**Symptom:** Relay `warlockrpi4` not publishing descriptors; IPv4 ORPort unreachable

---

## Diagnosis

### What the logs said

```
[notice] Unable to find IPv4 address for ORPort 9001.
[warn]   Your server has not managed to confirm reachability for its ORPort(s)
         at 69.212.112.252:9001. Relays do not publish descriptors until their
         ORPort(s) are reachable.
```

Meanwhile, this appeared seconds after Tor started:

```
[notice] Self-testing indicates your ORPort [2600:1700:269:450::44]:9001
         is reachable from the outside. Excellent.
```

### Root cause

The RPi4 sits behind a residential NAT router (ARRIS, AT&T, `192.168.1.254`). IPv6 is natively routed — no NAT — so the IPv6 ORPort works immediately. IPv4 requires the router to forward TCP port 9001 (and 9030) to `192.168.1.165`, but no such rule existed.

The UFW ruleset on the RPi4 was already correct:

```
9001/tcp     ALLOW IN    Anywhere    # Tor ORPort
9030/tcp     ALLOW IN    Anywhere    # Tor DirPort
```

The missing piece was entirely at the router.

### Why UPnP didn't help

`miniupnpc` was tested:

```bash
sudo apt-get install miniupnpc
upnpc -l
# No IGD UPnP Device found on the network !
```

UPnP is disabled on this gateway. There is no programmable API; port forwarding must be configured via the router's web UI using the Access Code printed on the device label.

---

## Fixes Applied

### 1. Static IP via NetworkManager

The RPi4's LAN IP was DHCP-assigned. If it ever changed, the router's port-forward target would silently break. Converted to static (same address — no SSH drop):

```bash
sudo nmcli con mod "Wired connection 1" \
  ipv4.addresses 192.168.1.165/24 \
  ipv4.gateway   192.168.1.254 \
  ipv4.dns       "8.8.8.8,1.1.1.1" \
  ipv4.method    manual
sudo nmcli con up "Wired connection 1"
```

Verify: `ip -4 addr show eth0` → `valid_lft forever`

### 2. Explicit `Address` in torrc

Without this, Tor logs a startup notice and spends ~1 minute discovering its external IP via an external probe before it can begin self-testing. Adding `Address` eliminates that delay:

```
Address 69.212.112.252
```

> If the ISP reassigns the public IP:
> ```bash
> NEW_IP=$(curl -s https://api.ipify.org)
> sudo sed -i "s/^Address .*/Address $NEW_IP/" /etc/tor/torrc
> sudo systemctl reload tor@default
> ```

Full torrc after changes:

```
SocksPort 0
Log notice file /var/log/tor/notices.log
Log notice syslog
DataDirectory /var/lib/tor

Nickname warlockrpi4
ContactInfo 0xGRANIT granittwosilo AT gmail DOT com
ORPort 9001
DirPort 9030
Address 69.212.112.252

ExitPolicy reject *:*
ExitRelay 0

ControlPort 9051
HashedControlPassword 16:27CEFAC2F9ACF9F660841387903F0F749DACE165174E7918D20F54AC86

DirCache 1
```

### 3. Relay health-check script

`/usr/local/bin/tor-relay-verify` — run after any Tor/network config change to get a full status snapshot.

```bash
#!/bin/bash
# Tor relay port-forward and descriptor publication verifier
# warlockrpi4 — 2026-04-26
# Usage: sudo tor-relay-verify

FINGERPRINT="88D420070BC10E6ECE57AA9F040AC4F82192A09C"
OR_PORT=9001
DIR_PORT=9030
LOG=/var/log/tor/notices.log

sep() { printf '%0.s-' {1..60}; echo; }

echo "=== tor-relay-verify  $(date) ==="
sep

# 1. External IP vs torrc
EXT_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null)
CONF_ADDR=$(grep -E '^Address ' /etc/tor/torrc | awk '{print $2}')
echo "External IPv4  : ${EXT_IP:-UNKNOWN}"
echo "torrc Address  : ${CONF_ADDR:-not set (auto-detect)}"
if [[ -n "$EXT_IP" && -n "$CONF_ADDR" && "$EXT_IP" != "$CONF_ADDR" ]]; then
  echo "  WARNING: IP mismatch — edit torrc then: systemctl reload tor@default"
fi
sep

# 2. Port reachability via hairpin probe
echo "Port reachability (hairpin probe via external IP):"
python3 - "$EXT_IP" << 'PYEOF'
import socket, sys
host = sys.argv[1]
for port, label in [(9001,"ORPort"), (9030,"DirPort")]:
    s = socket.socket(); s.settimeout(5)
    r = s.connect_ex((host, port))
    print(f"  TCP {port} ({label}): {'OPEN' if r==0 else f'CLOSED errno={r}'}")
    s.close()
PYEOF
sep

# 3. Tor control port
echo "Tor control port:"
python3 - << 'PYEOF'
import socket, time
s = socket.socket(); s.settimeout(6)
try:
    s.connect(("127.0.0.1", 9051))
    s.sendall(b'AUTHENTICATE "warlockrpi4"\r\n'); time.sleep(0.2); s.recv(1024)
    for key in [b"status/reachability-succeeded/or", b"net/listeners/or",
                b"fingerprint", b"address"]:
        s.sendall(b"GETINFO " + key + b"\r\n"); time.sleep(0.2)
        val = s.recv(4096).decode(errors="replace").strip()
        label = key.decode().split("/")[-1]
        val_line = next((l for l in val.splitlines() if "=" in l), val.splitlines()[0])
        print(f"  {label:35s}: {val_line.split('=',1)[-1] if '=' in val_line else val_line}")
    s.sendall(b"QUIT\r\n")
except Exception as e:
    print(f"  control port error: {e}")
finally:
    s.close()
PYEOF
sep

# 4. Recent reachability log
echo "Recent reachability log:"
grep -E "(reachab|descriptor|ORPort)" "$LOG" 2>/dev/null | tail -6 | sed 's/^/  /'
sep

# 5. Onionoo consensus check
echo "Tor network visibility (onionoo):"
tmpfile=$(mktemp)
curl -s --max-time 15 \
  "https://onionoo.torproject.org/summary?search=${FINGERPRINT}" > "$tmpfile" 2>/dev/null
python3 - "$tmpfile" << 'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
relays = data.get("relays", [])
if relays:
    r = relays[0]
    print(f"  VISIBLE in consensus")
    print(f"    nickname={r.get('n','?')}  running={r.get('r','?')}  flags={r.get('f',[])} ")
else:
    print("  NOT in consensus yet")
    print("  → fix port forward → Tor self-test passes → allow ~1hr to propagate")
PYEOF
rm -f "$tmpfile"
sep
echo "Done."
```

**Install:**

```bash
sudo tee /usr/local/bin/tor-relay-verify > /dev/null < tor-relay-verify.sh
sudo chmod +x /usr/local/bin/tor-relay-verify
```

### 4. Boot verification service

Runs `tor-relay-verify` automatically 5 minutes after Tor starts on every boot. The delay allows Tor's reachability self-test to complete before the check runs.

`/etc/systemd/system/tor-relay-verify.service`:

```ini
[Unit]
Description=Tor relay port-forward and descriptor verifier
After=tor@default.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 300
ExecStart=/usr/local/bin/tor-relay-verify
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
```

**Enable:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable tor-relay-verify.service
```

**Check output after boot:**

```bash
sudo journalctl -u tor-relay-verify --no-pager
```

---

## Router Port Forward — Manual Step

The ARRIS gateway has no API. This is a one-time manual config:

1. Open **http://192.168.1.254** in a browser
2. Log in with the **Access Code** on the router label (bottom/back of device)
3. Navigate to **Firewall → NAT/Gaming** (exact path varies by firmware)
4. Add two rules:

| Name | Protocol | External Port | Internal IP | Internal Port |
|------|----------|---------------|-------------|---------------|
| Tor-ORPort | TCP | 9001 | 192.168.1.165 | 9001 |
| Tor-DirPort | TCP | 9030 | 192.168.1.165 | 9030 |

5. Save and apply.

**Verification (within 20 minutes of saving):**

```bash
sudo tor-relay-verify
```

Expected output after a successful port forward:

```
Port reachability (hairpin probe via external IP):
  TCP 9001 (ORPort): OPEN
  TCP 9030 (DirPort): OPEN

Tor control port:
  reachability-succeeded/or          : 1

Recent reachability log:
  Self-testing indicates your ORPort 69.212.112.252:9001 is reachable
  from the outside. Excellent.
```

The relay will appear in the Tor consensus (onionoo) within ~1 hour of the self-test passing.

---

## Key Facts

| Item | Value |
|------|-------|
| Relay nickname | `warlockrpi4` |
| Fingerprint (RSA) | `88D420070BC10E6ECE57AA9F040AC4F82192A09C` |
| Fingerprint (Ed25519) | `P+gNQ4xR8Wx5rwrd++XKxwbZQb8pq9Qqx7ooizEb9TM` |
| rpi4 LAN IP | `192.168.1.165` (static, persists across reboots) |
| rpi4 MAC | `e4:5f:01:e3:c4:b8` |
| External IPv4 | `69.212.112.252` (residential DHCP — may change) |
| Router | ARRIS (AT&T), `192.168.1.254` |
| ORPort | 9001/tcp |
| DirPort | 9030/tcp |
| ControlPort | 9051 (localhost only) |
| IPv6 status | Working — `[2600:1700:269:450::44]:9001` passes self-test |

---

## Lessons Learned

### IPv6 passes, IPv4 fails — always check NAT first

If IPv6 reachability succeeds but IPv4 fails, the answer is almost always NAT. IPv6 is typically routed natively by ISPs (no NAT), so IPv6 ports are reachable without any router config. IPv4 requires explicit port forwarding.

Check immediately: `upnpc -l` — if UPnP is disabled, you need the router admin UI.

### UPnP is often disabled on ISP-provided gateways

AT&T residential gateways ship with UPnP disabled. Don't rely on it. Plan for manual port forwarding or consider a VPS/VPN for public services if the router is not under your control.

### DHCP target + port forward = silent future breakage

A port-forward rule pointing at a DHCP-assigned IP will silently break if the lease changes. Always set a static IP (or DHCP reservation by MAC) before adding port-forward rules. On NetworkManager:

```bash
sudo nmcli con mod "Wired connection 1" ipv4.method manual \
  ipv4.addresses <CURRENT_IP>/24 ipv4.gateway <GW> ipv4.dns "8.8.8.8,1.1.1.1"
sudo nmcli con up "Wired connection 1"
```

### Tor control port: no banner, client writes first

Tor's control port does not send a banner on connect. Any code that calls `recv()` before sending `AUTHENTICATE` will hang indefinitely. The correct sequence:

```python
s.connect(("127.0.0.1", 9051))
s.sendall(b'AUTHENTICATE "password"\r\n')  # write first
time.sleep(0.2)
resp = s.recv(1024)  # then read
```

Useful control port GETINFO keys for relay health:

| Key | Returns |
|-----|---------|
| `status/reachability-succeeded/or` | `1` if IPv4 self-test passed, else `0` |
| `net/listeners/or` | Active OR port bindings |
| `fingerprint` | RSA identity fingerprint |
| `address` | Detected external IP |

### Hairpin NAT for port-check probes

Testing whether port 9001 is reachable from outside is tricky from inside the NAT. The easiest approach: connect from the LAN host to the *external* IP (hairpin NAT). If the router supports it (errno=0), the port is open; if errno=111 (ECONNREFUSED), it's not forwarded. This works without any external service or VPS.

```python
import socket
s = socket.socket(); s.settimeout(5)
r = s.connect_ex(("69.212.112.252", 9001))
print("open" if r == 0 else f"closed (errno={r})")
```

`errno=111` = ECONNREFUSED (router rejects, port not forwarded)  
`errno=110` = ETIMEDOUT (silently dropped)  
`errno=0`   = connection succeeded (port is open and forwarded)
