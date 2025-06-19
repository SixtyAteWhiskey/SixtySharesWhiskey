#!/bin/bash
set -e

function print_usage() {
  echo
  echo "Usage: $0 --country=CODE --password=PASSWORD"
  echo
  echo "Options:"
  echo "  --country=CODE       Two-letter country code (e.g., US, PL)"
  echo "  --password=PASSWORD  Password string (e.g., mySecret123)"
  echo
  echo "Both options are required."
  echo "Example:"
  echo "  $0 --country=PL --password=secret123"
  echo
  exit 1
}

# Default values
COUNTRY="US"
PASSWORD="CHANGEME"

# Parse arguments
for arg in "$@"
do
  case $arg in
    --country=*)
      COUNTRY="${arg#*=}"
      ;;
    --password=*)
      PASSWORD="${arg#*=}"
      ;;
    *)
      echo "Unknown argument: $arg"
      print_usage
      ;;
  esac
done

if [[ -z "$COUNTRY" || -z "$PASSWORD" ]]; then
  echo "Error: --country and --password are required."
  print_usage
fi

if [[ ! "$COUNTRY" =~ ^[A-Z]{2}$ ]]; then
  echo "Error: --country must be exactly two uppercase letters (e.g., US, PL, DE)."
  exit 1
fi


echo "[*] Updating system..."
sudo apt-get update && sudo apt-get full-upgrade -y
echo "***********************************************************"
echo "*****YOU MUST SET YOUR WLAN COUNTRY UNDER LOCALIZATION*****"
echo "***********************************************************"
read -p "Press [Enter] to continue…"
sudo raspi-config

echo "[*] Installing required packages (auto-accept dhcpcd.conf)..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y \
  -o Dpkg::Options::="--force-confnew" \
  hostapd dnsmasq nginx python3 python3-pip python3-venv git dhcpcd5

echo "[*] Disabling wpa_supplicant on wlan0 to allow hostapd to control it..."
sudo systemctl stop wpa_supplicant.service || true
sudo systemctl disable wpa_supplicant.service || true

echo "[*] Patching /etc/hosts for hostname resolution..."
HOSTNAME=$(hostname)
if ! grep -q "127.0.1.1" /etc/hosts; then
    echo "127.0.1.1       $HOSTNAME" | sudo tee -a /etc/hosts
else
    sudo sed -i "s/^127.0.1.1.*/127.0.1.1       $HOSTNAME/" /etc/hosts
fi

echo "[*] Stopping interfering services (hostapd, dnsmasq)..."
sudo systemctl stop hostapd || true
sudo systemctl stop dnsmasq || true

echo "[*] Configuring static IP for wlan0 via dhcpcd..."
# 1) Remove any existing 'interface wlan0' blocks
for i in 1 2; do
  sudo sed -i '/^interface wlan0/,+3d' /etc/dhcpcd.conf
done

# 2) Append exactly one fresh stanza with "nolink"
sudo tee -a /etc/dhcpcd.conf > /dev/null <<\EOL

interface wlan0
    static ip_address=10.10.10.1/24
    nohook wpa_supplicant
    nolink
EOL

echo "[*] Restarting dhcpcd to apply static IP..."
sudo systemctl restart dhcpcd

# 3) Verify that dhcpcd actually gave wlan0 10.10.10.1—even if “state DOWN.”
if ! ip addr show wlan0 | grep -q "10.10.10.1/24"; then
  echo "WARNING: wlan0 did not get 10.10.10.1/24"
fi

echo "[*] Configuring dnsmasq..."
sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig || true
sudo tee /etc/dnsmasq.conf > /dev/null <<EOL
interface=wlan0
dhcp-range=10.10.10.10,10.10.10.100,24h
address=/#/10.10.10.1
EOL

sudo systemctl restart dnsmasq

echo "[*] Moving hostapd configuration"
sudo mkdir -p /etc/hostapd
sed -i \
  -e "s/^country_code=XX[[:space:]]*# ← change to your country code/country_code=$COUNTRY/" \
  -e "s/^wpa_passphrase=CHANGEME/wpa_passphrase=$PASSWORD/" \
  hostapd.conf
sudo mv hostapd.conf /etc/hostapd/

sudo tee /etc/default/hostapd > /dev/null <<EOL
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOL

# Create a systemd override so hostapd waits for dhcpcd
echo "[*] Ensuring hostapd waits for dhcpcd on boot..."
sudo mkdir -p /etc/systemd/system/hostapd.service.d
sudo tee /etc/systemd/system/hostapd.service.d/override.conf > /dev/null <<EOL
[Unit]
Wants=network-online.target dhcpcd.service
After=network-online.target dhcpcd.service
EOL

sudo systemctl unmask hostapd
sudo systemctl daemon-reload
sudo systemctl enable hostapd

echo "[*] Restarting hostapd..."
sudo systemctl restart hostapd

echo "[*] Enabling IP forwarding..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

echo "[*] Setting up NGINX for web GUI..."
sudo mkdir -p /srv/sixtyshareswhiskey/uploads
sudo touch /srv/sixtyshareswhiskey/chat.log
sudo find /srv/sixtyshareswhiskey -type d -exec chmod 755 {}
sudo find /srv/sixtyshareswhiskey -type f -exec chmod 644 {}


echo "[*] Preparing certificates..."
sudo openssl req -x509 -newkey rsa:4096 \
  -keyout /srv/sixtyshareswhiskey/certs/key.pem \
  -out /srv/sixtyshareswhiskey/certs/cert.pem \
  -days 1 \
  -nodes \
  -subj "/C=XX/ST=$HOSTNAME/L=$HOSTNAME/O=$HOSTNAME/OU=$HOSTNAME/CN=127.0.0.1"
sudo chmod 600 /srv/sixtyshareswhiskey/certs/key.pem
sudo chmod 644 /srv/sixtyshareswhiskey/certs/cert.pem

echo "[*] Moving server conf to nginx sites-available"
sudo mv sixtyshareswhiskey /etc/nginx/sites-available/ 
sudo ln -sf /etc/nginx/sites-available/sixtyshareswhiskey /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

echo "[*] Patching nginx.conf for global client_max_body_size override..."
if ! grep -q "client_max_body_size" /etc/nginx/nginx.conf; then
    sudo sed -i '/http {/a \    client_max_body_size 0;' /etc/nginx/nginx.conf
else
    sudo sed -i 's/client_max_body_size .*/client_max_body_size 0;/' /etc/nginx/nginx.conf
fi

echo "[*] Setting up Python virtual environment for Flask..."
sudo mkdir -p /srv/sixtyshareswhiskey
sudo chown "$(whoami):$(whoami)" /srv/sixtyshareswhiskey
python3 -m venv /srv/sixtyshareswhiskey/venv
source /srv/sixtyshareswhiskey/venv/bin/activate
/srv/sixtyshareswhiskey/venv/bin/pip install --upgrade pip flask

echo "[*] Moving Flask backend (with anonymous chat)..."
mv app.py /srv/sixtyshareswhiskey/

echo "[*] Moving minimal HTML frontend (with upload + chat)..."
mv index.html style.css /srv/sixtyshareswhiskey/

echo "[*] Moving cleanup script..."
mv cleanup.sh /srv/sixtyshareswhiskey/
sudo chmod +x /srv/sixtyshareswhiskey/cleanup.sh

echo "[*] Scheduling cleanup every day at midnight..."
sudo crontab -l 2>/dev/null > /tmp/mycron || true
echo "@daily /srv/sixtyshareswhiskey/cleanup.sh" >> /tmp/mycron
sudo crontab /tmp/mycron
rm /tmp/mycron

echo "[*] Creating systemd service for Flask app..."
mv sixtyshareswhiskey.service /etc/systemd/system/ 

echo "[*] Enabling and starting services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable sixtyshareswhiskey
sudo systemctl start sixtyshareswhiskey
sudo systemctl restart nginx
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq
sudo systemctl restart hostapd
sudo systemctl restart dnsmasq

echo "[✓] SixtySharesWhiskey is ready. Connect to the hotspot and visit https://10.10.10.1"
echo "[*] Thank you for installing, God Bless!"
echo "[*] - Sixty"
