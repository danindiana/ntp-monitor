# ntp-monitor

A lightweight LAN web dashboard for NTP telemetry and clock-drift anomaly detection.

Designed for headless Raspberry Pi (arm64) but works on any Debian/Ubuntu system with `ntpsec` and `nginx`.

![dark dashboard showing NTP peer table and offset sparkline](https://raw.githubusercontent.com/danindiana/ntp-monitor/main/screenshot.png)

## Motivation

NTP server poisoning and BGP hijacks that redirect NTP traffic are real threats. A local monitor lets you watch for:

- Sudden large offset jumps (>50 ms vs recent average) — key poisoning indicator
- Peer disagreement — spread >200 ms across reachable peers suggests a rogue server
- Stratum drift — your selected peer silently moving to a worse stratum
- Peer loss — dropping below 2 usable peers removes protection by majority vote

## Features

- **Live peer table** — status, remote, refid, stratum, reach %, delay, offset, jitter
- **Offset sparkline** — 120-sample (2h) SVG trend chart with min/max labels
- **Anomaly detection** — colour-coded alerts with severity (🔴 critical / 🟡 warning)
- **24h history** — rolling JSON log at `/var/lib/ntp-monitor/history.json`
- **Auto-refresh** — page refreshes every 60 seconds
- **Zero JS dependencies** — pure HTML/SVG/CSS, works on any browser

## Requirements

- Debian 12+ / Raspberry Pi OS Bookworm or Trixie
- `ntpsec` (replaces `systemd-timesyncd`)
- `nginx`
- Python 3.10+

## Install

```bash
git clone https://github.com/danindiana/ntp-monitor.git
cd ntp-monitor
bash install.sh
```

Dashboard will be at `http://<device-ip>/` or `http://<hostname>.local/`.

## File layout

```
/usr/local/bin/ntp-monitor-update      # generator script (runs every minute via cron)
/var/www/html/ntp/index.html           # generated dashboard
/var/lib/ntp-monitor/history.json      # rolling 24h offset history
/etc/nginx/sites-available/ntp-monitor # nginx site config
/etc/cron.d/                           # via root crontab
```

## Anomaly thresholds (configurable in script header)

| Constant       | Default  | Meaning                                        |
|----------------|----------|------------------------------------------------|
| `OFFSET_ALERT` | 100.0 ms | Warn if selected peer offset exceeds this      |
| `JUMP_ALERT`   | 50.0 ms  | Warn if offset jumps vs recent 10-sample avg   |
| `STRATUM_ALERT`| 4        | Warn if selected peer stratum ≥ this           |

## Security notes

- Dashboard is LAN-only (bind nginx to your LAN interface or firewall port 80 from WAN)
- History file is world-readable — contains no credentials, only NTP telemetry
- Script runs as root (required for `ntpq`) — review before deploying on untrusted hosts

## License

MIT
