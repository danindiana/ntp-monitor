# RPi4 Hardening Guide — Tor Relay + NTP Monitor Host

**Date:** 2026-04-25  
**Host:** rpi4 — Debian Trixie (aarch64), 192.168.1.165  
**Role:** LAN NTP telemetry dashboard + Tor middle relay

This document captures everything done to harden the RPi4 that runs the ntp-monitor dashboard, add a Tor middle relay, and fix two boot-time bugs discovered during testing. It is intended as a reproducible runbook for this or a similar host.

---

## Table of Contents

1. [Host baseline](#host-baseline)
2. [Tor middle relay](#tor-middle-relay)
3. [Nyx — Tor relay monitor](#nyx--tor-relay-monitor)
4. [UFW firewall](#ufw-firewall)
5. [fail2ban IDS](#fail2ban-ids)
6. [Boot testing and bugs fixed](#boot-testing-and-bugs-fixed)
7. [Login MOTD](#login-motd)
8. [Lessons learned](#lessons-learned)
9. [Quick reference](#quick-reference)

---

## Host baseline

| Item | Value |
|------|-------|
| OS | Debian GNU/Linux 13 (trixie) |
| Kernel | 6.12.75+rpt-rpi-v8 aarch64 |
| IP | 192.168.1.165 (DHCP, stable) |
| RAM | 855 MiB |
| Root | USB SSD, 118 GB |
| SSH | `ssh rpi4` from worlock (192.168.1.135) |

Pre-existing services: `nginx` (NTP dashboard on :80), `ntpsec`, `ssh`, `avahi-daemon`.

---

## Tor middle relay

### Install

```bash
sudo apt-get install tor nyx
```

### Configuration — `/etc/tor/torrc`

```
SocksPort 0

Log notice file /var/log/tor/notices.log
Log notice syslog

DataDirectory /var/lib/tor

Nickname warlockrpi4
ContactInfo 0xGRANIT granittwosilo AT gmail DOT com
ORPort 9001
DirPort 9030

# No RelayBandwidthRate/Burst set — unlimited (host runs 24/7)

ExitPolicy reject *:*
ExitRelay 0

ControlPort 9051
HashedControlPassword 16:27CEFAC2F9ACF9F660841387903F0F749DACE165174E7918D20F54AC86

DirCache 1
```

Generate a new hashed password with: `tor --hash-password 'yourpassword'`

### Tor service notes

The Debian package uses a multi-instance systemd setup:
- `tor.service` — master unit (enabled at boot, runs `/bin/true`)
- `tor@default.service` — actual daemon (started by the master)

`tor@default` does not support `systemctl enable` directly; it is controlled via the master. It will start automatically at boot as long as `tor.service` is enabled.

### Relay identity

| Item | Value |
|------|-------|
| Fingerprint (RSA) | `88D420070BC10E6ECE57AA9F040AC4F82192A09C` |
| Fingerprint (Ed25519) | `P+gNQ4xR8Wx5rwrd++XKxwbZQb8pq9Qqx7ooizEb9TM` |
| External IP | 69.212.112.252 |
| Type | Middle relay (no exit) |

New relays enter the directory after ~3 hours. `Stable` and `HSDir` flags appear after ~8 days of continuous uptime.

Track: https://metrics.torproject.org/rs.html#search/warlockrpi4

---

## Nyx — Tor relay monitor

Nyx is a curses TUI that connects to the Tor control port and shows bandwidth, circuits, logs, and relay health in real time.

### Config — `~/.nyx/config` (on rpi4)

```
control_port 127.0.0.1:9051
password warlockrpi4
```

### Usage

```bash
# From worlock
ssh -t rpi4 nyx

# Convenience wrapper installed on worlock
nyx-rpi4        # /usr/local/bin/nyx-rpi4
```

---

## UFW firewall

### Install and configure

```bash
sudo apt-get install ufw
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny forward

sudo ufw allow in on lo comment 'loopback'
sudo ufw allow from 192.168.1.0/24 to any port 22  proto tcp comment 'SSH LAN'
sudo ufw allow from 192.168.1.0/24 to any port 80  proto tcp comment 'NTP web LAN'
sudo ufw allow from 192.168.1.0/24 to any port 123 proto udp comment 'NTP LAN'
sudo ufw allow from 192.168.1.0/24 to any port 5353 proto udp comment 'mDNS LAN'
sudo ufw allow 9001/tcp comment 'Tor ORPort'
sudo ufw allow 9030/tcp comment 'Tor DirPort'

sudo ufw --force enable
```

### Port policy rationale

| Port | Proto | Access | Reason |
|------|-------|--------|--------|
| lo | any | Unrestricted | Loopback always open |
| 22 | TCP | LAN only | SSH — no internet exposure needed |
| 80 | TCP | LAN only | NTP dashboard is a private tool |
| 123 | UDP | LAN only | NTP service — LAN clients only |
| 5353 | UDP | LAN only | Avahi mDNS — local discovery only |
| 9001 | TCP | World | Tor relay **must** accept connections from anywhere |
| 9030 | TCP | World | Tor directory **must** be world-reachable |
| 9051 | TCP | Loopback | Tor control port — bound to 127.0.0.1, no UFW rule needed |

UFW uses the `iptables-nft` backend on Debian Trixie (`iptables v1.8.11 (nf_tables)`).

---

## fail2ban IDS

### Install

```bash
sudo apt-get install fail2ban
```

### Configuration — `/etc/fail2ban/jail.local`

```ini
[DEFAULT]
# Never ban LAN or loopback — worlock will never be locked out
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24

# UFW banaction: bans appear in 'sudo ufw status'
banaction = ufw
banaction_allports = ufw

findtime  = 10m
bantime   = 1h
maxretry  = 5

# Repeat offenders get exponentially longer bans, capped at 1 week
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w

action = %(action_)s
logtarget = SYSLOG

[sshd]
enabled   = true
backend   = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
port      = 22
maxretry  = 4
bantime   = 2h
findtime  = 5m

[nginx-botsearch]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/access.log
maxretry = 2
bantime  = 6h

[nginx-bad-request]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/access.log
maxretry = 3
bantime  = 1h
```

### Design decisions

- **`banaction = ufw`** instead of the Debian default `nftables`: bans are managed via `ufw deny from <IP>`, so they appear in `ufw status` and are visible alongside firewall rules. The two backends (UFW/iptables-nft and direct nftables) would not conflict, but UFW integration is cleaner for a UFW-managed host.

- **`ignoreip` includes the full LAN subnet**: the LAN is trusted and the NTP dashboard is LAN-only; locking out worlock via fail2ban would be self-defeating.

- **Escalating bans**: `bantime.increment=true` with `factor=2` and `maxtime=1w` means a first offense gets 2h, second 4h, third 8h, etc. Persistent attackers are eventually banned for a week without manual intervention.

### Useful commands

```bash
sudo fail2ban-client status              # list jails
sudo fail2ban-client status sshd        # details + current bans
sudo fail2ban-client unban <IP>         # manual unban
sudo ufw status                         # see active bans as UFW rules
```

---

## Boot testing and bugs fixed

Two bugs were discovered and fixed during boot testing (three reboots total).

### Bug 1 — `/var/log/tor/` missing after reboot

**Symptom:**
```
[warn] Couldn't open file for 'Log notice file /var/log/tor/notices.log': No such file or directory
[err]  Reading config failed--see warnings above.
```
`tor@default` entered a restart loop and hit the restart limit within seconds.

**Root cause:** The Tor Debian package creates `/var/log/tor/` only in its postinstall script. On this system image the directory was absent. The directory is on the persistent root filesystem, not a tmpfs, so the package should have ensured it exists — but it didn't. The postinstall script even warned: *"Something or somebody made /var/log/tor disappear."*

**Fix:**

```bash
# Create /etc/tmpfiles.d/tor.conf
echo 'd /var/log/tor 0750 debian-tor debian-tor -' | sudo tee /etc/tmpfiles.d/tor.conf

# Apply immediately (no reboot required)
sudo systemd-tmpfiles --create /etc/tmpfiles.d/tor.conf
```

`systemd-tmpfiles-setup.service` runs early in every boot sequence and recreates the directory before any service starts.

Also added `Log notice syslog` as a second log destination in torrc so logs always reach journald even if the file path fails.

---

### Bug 2 — Clock skew warning at boot (Nyx: "Our clock is 5 hours, 14 minutes behind")

**Symptom (from Nyx log panel):**
```
[WARN] Clock skew -18842 in microdesc flavor consensus from CONSENSUS
[WARN] Our clock is 5 hours, 14 minutes behind the time published in the consensus
       network status document (2026-04-25 23:00:00 UTC).
```

**Root cause:** The RPi4 has **no hardware real-time clock (RTC)**. On every cold boot the system clock starts at the last-saved time (or epoch if never saved). `tor@default` was starting before `ntpsec` had synchronized the clock. Tor connected to the network, fetched the consensus document, compared timestamps, and found its local clock was hours behind — resulting in WARN messages and a slow/stuck bootstrap.

**Why it eventually worked anyway:** Tor's clock-skew check is a warning, not a hard failure, unless the skew exceeds a threshold (typically 1 hour for the consensus, but Tor continues trying). By the time enough circuits were built, ntpsec had corrected the clock and subsequent consensus fetches passed cleanly.

**Fix — three-layer approach:**

#### Layer 1: `fake-hwclock` (coarse clock persistence)

```bash
sudo apt-get install fake-hwclock
# Saves /etc/fake-hwclock.data hourly + at shutdown
# Restores it at boot via fake-hwclock-load.service (sysinit.target)
# Result: cold boot starts within minutes of reality, not hours off
```

#### Layer 2: `ntpsec-wait.service` (fine sync gate)

Ships with ntpsec but not enabled by default:

```bash
sudo systemctl enable ntpsec-wait.service
```

This runs `ntpwait -s 1 -n 30000` — polling ntpsec every second until it achieves synchronization — then activates `time-sync.target`. With `fake-hwclock` reducing initial skew, sync typically completes within 20–30 seconds of boot.

#### Layer 3: `tor@default` dependency on `time-sync.target`

```bash
sudo mkdir -p /etc/systemd/system/tor@default.service.d
sudo tee /etc/systemd/system/tor@default.service.d/wait-for-clock.conf << 'EOF'
[Unit]
After=time-sync.target
Wants=time-sync.target
EOF
sudo systemctl daemon-reload
```

Tor now sits in `inactive` state until `time-sync.target` fires. Once the clock is good, Tor starts and connects with a correct timestamp — zero clock-skew WARNs.

**Verified boot sequence after fix:**

| Time | Event |
|------|-------|
| T+0s | Boot; `fake-hwclock` restores saved time |
| T+~25s | `ntpsec` syncs; `ntpsec-wait` activates `time-sync.target` |
| T+~28s | `tor@default` unblocked and starts |
| T+~43s | Tor bootstrap 100% — no WARNs in log |

---

## Login MOTD

A dynamic MOTD script shows live service status on every SSH login.

**Location:** `/etc/update-motd.d/50-services`

**Sample output:**
```
SERVICE                STATUS   DETAILS
------------------------------------------------------------
tor@default          OK        relay warlockrpi4  boot=done fp=...88D420070BC10E6E
tor ORPort 9001      OK        world-reachable (middle relay, no exit)
tor DirPort 9030     OK        world-reachable (directory mirror)
ufw firewall         OK        10 rules active
fail2ban             OK        3 jails  sshd banned=0
ssh                  OK        port 22 (LAN only: 192.168.1.0/24)
nginx / ntp-monitor  OK        http://192.168.1.165/  [HTTP 200]
ntpsec               OK        synced=yes  peer=*as393746.mci.tr
time-sync.target     OK        (blocks tor until clock OK)
------------------------------------------------------------
IP: 192.168.1.165  2026-04-26 01:12:56 BST
```

Run manually at any time: `sudo /etc/update-motd.d/50-services`

---

## Lessons learned

### 1. Always reboot-test after configuring services

Services that work after manual install/restart may silently fail at boot due to missing directories, wrong ordering, or tmpfs vs. persistent filesystem assumptions. Running `systemctl restart` is not equivalent to a cold boot. In this session, both bugs only appeared on first reboot.

### 2. RPi4 has no hardware RTC — plan for it

Any time-sensitive service on an RPi4 (Tor, TLS cert validation, log correlation) needs a clock strategy:
- Install `fake-hwclock` immediately on any RPi4 deployment.
- Enable `ntpsec-wait.service` (or `systemd-timesyncd`'s equivalent) to get `time-sync.target`.
- Add `After=time-sync.target` to any service that cares about clock accuracy.

### 3. Tor's multi-instance systemd layout is non-obvious

The Debian Tor package uses `tor.service` (master, runs `/bin/true`) + `tor@default.service` (actual daemon). `systemctl enable tor@default` fails with a confusing message. The correct approach: enable `tor.service`; it pulls in `tor@default` automatically. Service drop-ins go in `/etc/systemd/system/tor@default.service.d/`.

### 4. fail2ban `banaction = ufw` on UFW hosts

The Debian Trixie default fail2ban `banaction` is `nftables`. Both `nftables` and `ufw` work alongside each other (they write to different chains), but on a host managed by UFW, using `banaction = ufw` is cleaner: bans show up in `ufw status`, are managed consistently, and are easier to audit.

### 5. tmpfiles.d is the right tool for persistent-but-not-packaged directories

If a package's postinstall script creates a directory that may not survive across reinstalls or system image snapshots, mirror it in `/etc/tmpfiles.d/`. The format is simple and the mechanism is reliable: `systemd-tmpfiles-setup.service` runs before any services start.

---

## Quick reference

```bash
# From worlock — Nyx relay monitor
nyx-rpi4                                  # /usr/local/bin/nyx-rpi4

# Firewall
ssh rpi4 sudo ufw status verbose

# fail2ban
ssh rpi4 sudo fail2ban-client status
ssh rpi4 sudo fail2ban-client status sshd

# Tor
ssh rpi4 sudo journalctl -u tor@default -f
ssh rpi4 sudo tail -f /var/log/tor/notices.log

# Clock / time sync
ssh rpi4 timedatectl
ssh rpi4 systemctl is-active time-sync.target

# Service wall
ssh rpi4 sudo /etc/update-motd.d/50-services

# Relay tracker (appears ~3h after first boot, Stable flag ~8 days)
# https://metrics.torproject.org/rs.html#search/warlockrpi4
```
