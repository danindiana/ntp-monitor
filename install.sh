#!/usr/bin/env bash
# ntp-monitor install script
# Tested on Raspberry Pi OS Trixie (Debian 13) arm64 — headless
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/6] Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y ntpsec nginx

echo "[2/6] Disabling systemd-timesyncd (conflicts with ntpsec)..."
sudo systemctl disable --now systemd-timesyncd 2>/dev/null || true

echo "[3/6] Enabling ntpsec..."
sudo systemctl enable --now ntpsec

echo "[4/6] Installing ntp-monitor-update script..."
sudo cp "$SCRIPT_DIR/ntp-monitor-update" /usr/local/bin/ntp-monitor-update
sudo chmod +x /usr/local/bin/ntp-monitor-update

echo "[5/6] Configuring nginx..."
sudo mkdir -p /var/www/html/ntp

# Ensure nginx log dir survives tmpfs /var/log (common on low-write setups)
sudo tee /etc/tmpfiles.d/nginx.conf > /dev/null << 'EOF'
d /var/log/nginx 0755 root adm -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/nginx.conf

sudo cp "$SCRIPT_DIR/nginx/ntp-monitor.conf" /etc/nginx/sites-available/ntp-monitor
sudo ln -sf /etc/nginx/sites-available/ntp-monitor /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx

echo "[6/6] Setting up cron (every minute)..."
(sudo crontab -l 2>/dev/null | grep -v ntp-monitor-update
 echo '* * * * * /usr/local/bin/ntp-monitor-update && chown www-data:www-data /var/www/html/ntp/index.html'
) | sudo crontab -

echo "[+] Running first update..."
sudo /usr/local/bin/ntp-monitor-update
sudo chown -R www-data:www-data /var/www/html/ntp

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "Done. Dashboard available at:"
echo "  http://${IP}/"
echo "  http://$(hostname).local/"
