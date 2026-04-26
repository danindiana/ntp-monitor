# AT&T ARRIS Gateway — Port Forwarding for Tor Relay

**Router:** ARRIS (AT&T residential gateway)  
**Admin UI:** http://192.168.1.254  
**Goal:** Forward TCP 9001 (ORPort) and 9030 (DirPort) to rpi4 at 192.168.1.165

This is the one manual step that cannot be automated — UPnP is disabled on this
gateway and there is no programmable API. It takes about 2 minutes.

---

## Step 1 — Find the Access Code

Look at the physical router. There is a sticker on the **side or bottom** of the
device labeled **"Access Code"** — a 10–12 character alphanumeric string. That is
the admin password for the web UI.

---

## Step 2 — Log in

Open a browser on the LAN and go to:

```
http://192.168.1.254
```

Enter the Access Code when prompted.

---

## Step 3 — Navigate to port forwarding

```
Home → Firewall → NAT/Gaming
```

> If you don't see **NAT/Gaming**, look for one of these depending on firmware:
> - **Firewall Settings → Applications, Pinholes and DMZ**
> - **Firewall → IP Passthrough** (routes all traffic to one host — more invasive)

---

## Step 4 — Add the two rules

Click **"Add a new user-defined application"** or **"Custom Services"**.

### Rule 1 — Tor ORPort

| Field | Value |
|-------|-------|
| Application name | `Tor-ORPort` |
| Protocol | TCP |
| External port | 9001 |
| Internal port | 9001 |
| Internal IP address | `192.168.1.165` |

Click **Add** (or **Save**).

### Rule 2 — Tor DirPort

| Field | Value |
|-------|-------|
| Application name | `Tor-DirPort` |
| Protocol | TCP |
| External port | 9030 |
| Internal port | 9030 |
| Internal IP address | `192.168.1.165` |

Click **Add** (or **Save**).

Then click **Apply** or **Save Settings** to commit both rules.

---

## Step 5 — Verify from rpi4

SSH into rpi4 and run the health-check script:

```bash
ssh rpi4 sudo tor-relay-verify
```

Within 20 minutes of saving the router rules Tor will self-test. A successful
result looks like this:

```
Port reachability (hairpin probe via external IP):
  TCP 9001 (ORPort): OPEN
  TCP 9030 (DirPort): OPEN

Tor control port:
  reachability-succeeded/or          : 1
  ...

Recent reachability log:
  Self-testing indicates your ORPort 69.212.112.252:9001 is reachable
  from the outside. Excellent.

Tor network visibility (onionoo):
  NOT in consensus yet
  → allow ~1hr to propagate
```

The relay appears in the Tor consensus about **1 hour** after the self-test passes.

Track it at:  
https://metrics.torproject.org/rs.html#search/warlockrpi4

---

## Troubleshooting

### Ports still show CLOSED after saving rules

- Confirm the internal IP in the rule is exactly `192.168.1.165` — not a
  different LAN address.
- Verify rpi4 is still on that IP: `ssh rpi4 ip -4 addr show eth0`
  (should show `192.168.1.165/24 ... valid_lft forever`).
- Check UFW on rpi4 allows the ports: `ssh rpi4 sudo ufw status verbose`
- Some AT&T firmwares require a **router reboot** after adding NAT rules.
  Power-cycle the gateway and re-run `tor-relay-verify`.

### External IP changed since torrc was written

If the ISP reassigned the public IP, update torrc:

```bash
ssh rpi4 "NEW_IP=\$(curl -s https://api.ipify.org) && \
  sudo sed -i \"s/^Address .*/Address \$NEW_IP/\" /etc/tor/torrc && \
  sudo systemctl reload tor@default && echo Updated to \$NEW_IP"
```

Then re-run `sudo tor-relay-verify`.

### IP Passthrough as a fallback

If NAT/Gaming rules refuse to stick or the firmware version doesn't support
per-port forwarding, **IP Passthrough** routes all inbound traffic to a single
LAN host. Navigate to:

```
Firewall → IP Passthrough
```

Set the passthrough device to `192.168.1.165` (or select rpi4 by MAC
`e4:5f:01:e3:c4:b8`). This opens all ports to rpi4, so ensure UFW is correct
before enabling it:

```bash
ssh rpi4 sudo ufw status verbose
# 9001/tcp and 9030/tcp must show ALLOW IN Anywhere
# 22/tcp must show ALLOW IN 192.168.1.0/24 (LAN only)
```

---

## Key addresses

| Item | Value |
|------|-------|
| Router admin | http://192.168.1.254 |
| rpi4 LAN IP | 192.168.1.165 (static) |
| rpi4 MAC | e4:5f:01:e3:c4:b8 |
| External IPv4 | 69.212.112.252 (residential DHCP) |
| Tor ORPort | TCP 9001 |
| Tor DirPort | TCP 9030 |
