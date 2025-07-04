#!/bin/bash
set -e

function print_usage() {
  echo
  echo "Usage: $0 --country=CODE --password=PASSWORD"
  echo
  echo "Options:"
  echo "  --country=CODE       Two-letter country code (e.g., US, PL)"
  echo "  --password=PASSWORD  Password string (e.g., mySecret123)"
  echo "  --mode=MODE          Defines mode of installation (kamikaze, standalone, daemon). Default mode is standalone"
  echo "Modes description:"
  echo "  --mode=standalone    Default mode: installs and runs with default settings."
  echo "  --mode=daemon        Similar to standalone, but does not change network settings; installs as a daemon bound to 0.0.0.0."
  echo "  --mode=kamikaze      Kamikaze mode: similar to standalone, but wipes entire installation after 24 hours, completely removing all traces."
  echo "  --mode=gateway       Similar to standalone, but uploads saved data to a specified location (e.g., external hard drive)."
  echo "  --mode=chat          Chat-only functionality; upload endpoint is blocked."
  echo "  --mode=file-server   File server only; serves files from a directory with no upload functionality."

  echo "Parameters--country and --password are required."
  echo "Example:"
  echo "  $0 --country=PL --password=secret123"
  echo
  exit 1
}

# Default values
COUNTRY="US"
PASSWORD="CHANGEME"
MODE="standalone"

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
    --mode=*)
      MODE="${arg#*=}"
      ;;
    *)
      echo "Unknown argument: $arg"
      print_usage
      ;;
  esac
done

function validate_script_parameters() {
  if [[ -z "$COUNTRY" || -z "$PASSWORD" ]]; then
    echo "Error: --country and --password are required."
    print_usage
  fi

  if [[ ! "$COUNTRY" =~ ^[A-Z]{2}$ ]]; then
    echo "Error: --country must be exactly two uppercase letters (e.g., US, PL, DE)."
    print_usage
  fi

  if [[ $MODE = "standalone" ]]; then
    echo "MODE is standalone, proceeding with standard installation"
    return 0
  elif [[ $MODE = "daemon" ]]; then
    echo "MODE is daemon, proceeding with daemon installation mode (no network changes, bound to 0.0.0.0)"
    return 0
  elif [[ $MODE = "kamikaze" ]]; then
    echo "MODE is kamikaze, proceeding with kamikaze installation mode (wipes installation after 24 hours)"
    return 0
  elif [[ $MODE = "gateway" ]]; then
    echo "MODE is gateway, proceeding with gateway installation mode (uploads data to specified location)"
    return 0
  elif [[ $MODE = "chat" ]]; then
    echo "MODE is chat, proceeding with chat-only functionality (upload endpoint blocked)"
    return 0
  elif [[ $MODE = "file-server" ]]; then
    echo "MODE is file-server, proceeding with file server only mode (serves files, no uploads)"
    return 0
  else
    echo "Unknown MODE: $MODE. Please specify a valid modes (standalone, daemon, kamikaze, gateway, chat, file-server)."
    print_usage
  fi
}


function validate_parameters() {
  echo "[*] Validating parameters"
  validate_script_parameters
}

function update_the_system() {
  echo "[*] Updating system..."
  sudo apt-get update && sudo apt-get full-upgrade -y || true
}

function install_dependencies_from_internet() {
  echo "[*] Installing required packages (auto-accept dhcpcd.conf)..."
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get install -y \
    -o Dpkg::Options::="--force-confnew" \
    nginx python3 python3-pip python3-venv git dhcpcd5
  if [[ $MODE == "standalone" ]]; then
    sudo apt-get install -y -o Dpkg::Options::="--force-confnew" hostapd dnsmasq
  fi
} 

function disable_wpa_supplicant_temp() {
  if [[ $MODE == "standalone" ]]; then
    echo "[*] Disabling wpa_supplicant on wlan0 to allow hostapd to control it..."
    sudo systemctl stop wpa_supplicant.service || true
    sudo systemctl disable wpa_supplicant.service || true
  else
    return 0
  fi
}


function patch_the_host_file() {
  echo "[*] Patching /etc/hosts for hostname resolution..."
  HOSTNAME=$(hostname)
  if ! grep -q "127.0.1.1" /etc/hosts; then
      echo "127.0.1.1       $HOSTNAME" | sudo tee -a /etc/hosts
  else
      sudo sed -i "s/^127.0.1.1.*/127.0.1.1       $HOSTNAME/" /etc/hosts
  fi
}

function stop_hostapd_and_dnsmasq() {
  echo "[*] Stopping interfering services (hostapd, dnsmasq)..."
  sudo systemctl stop hostapd || true
  sudo systemctl stop dnsmasq || true
}

function configure_static_IP() {
  echo "[*] Configuring static IP for wlan0 via dhcpcd..."
  # 1) Remove any existing 'interface wlan0' blocks
  for i in 1 2; do
    sudo sed -i '/^interface wlan0/,+3d' /etc/dhcpcd.conf
  done

  sudo mv dhcpd.conf /etc/dhcpcd.conf
}

function restart_dhcpd() {
  echo "[*] Restarting dhcpcd to apply static IP..."
  sudo systemctl restart dhcpcd

  # 3) Verify that dhcpcd actually gave wlan0 10.10.10.1—even if “state DOWN.”
  if ! ip addr show wlan0 | grep -q "10.10.10.1/24"; then
    echo "WARNING: wlan0 did not get 10.10.10.1/24"
  fi
}

function configure_dnsmask() {
  echo "[*] Configuring dnsmasq..."
  sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig || true
  sudo mv dnsmasq.conf /etc/dnsmasq.conf
  sudo systemctl restart dnsmasq
}

function move_hostapd_conf() {
  echo "[*] Moving hostapd configuration"
  sudo mkdir -p /etc/hostapd
  if [[ $MODE == "standalone" ]]; then
    sed -i \
      -e "s/^country_code=XX[[:space:]]*# ← change to your country code/country_code=$COUNTRY/" \
      -e "s/^wpa_passphrase=CHANGEME/wpa_passphrase=$PASSWORD/" \
      hostapd.conf
  fi
  sudo mv hostapd.conf /etc/hostapd/

  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee /etc/default/hostapd > /dev/null

  }

function configure_hostapd_to_wait_for_dhcpd() {
  echo "[*] Ensuring hostapd waits for dhcpcd on boot..."
  
  if [[ $MODE == "standalone" ]]; then
    sudo mkdir -p /etc/systemd/system/hostapd.service.d
    sudo mv override.conf /etc/systemd/system/hostapd.service.d/
  fi

  sudo systemctl unmask hostapd
  sudo systemctl daemon-reload
  sudo systemctl enable hostapd
}


function enable_IPv4_forwarding(){
  echo "[*] Enabling IP forwarding..."
  if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
      echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
  fi
  sudo sysctl -p
}


function configure_nginx() {
  echo "[*] Setting up NGINX for web GUI..."
  sudo mkdir -p /srv/sixtyshareswhiskey/uploads
  sudo touch /srv/sixtyshareswhiskey/chat.log
  sudo find /srv/sixtyshareswhiskey -type d -exec chmod 755 {} \;
  sudo find /srv/sixtyshareswhiskey -type f -exec chmod 644 {} \;
}

function prepare_certificates() {
  echo "[*] Preparing certificates..."
  mkdir -p /srv/sixtyshareswhiskey/certs/
  sudo openssl req -x509 -newkey rsa:4096 \
    -keyout /srv/sixtyshareswhiskey/certs/key.pem \
    -out /srv/sixtyshareswhiskey/certs/cert.pem \
    -days 1 \
    -nodes \
    -subj "/C=XX/ST=$HOSTNAME/L=$HOSTNAME/O=$HOSTNAME/OU=$HOSTNAME/CN=127.0.0.1"
  sudo chmod 600 /srv/sixtyshareswhiskey/certs/key.pem
  sudo chmod 644 /srv/sixtyshareswhiskey/certs/cert.pem
}


function move_nginx_conf() {
  echo "[*] Moving server conf to nginx sites-available"
  sudo mv sixtyshareswhiskey /etc/nginx/sites-available/ 
  sudo ln -sf /etc/nginx/sites-available/sixtyshareswhiskey /etc/nginx/sites-enabled/
  sudo rm -f /etc/nginx/sites-enabled/default
}

function enable_big_uploads() {
  echo "[*] Patching nginx.conf for global client_max_body_size override..."
  if ! grep -q "client_max_body_size" /etc/nginx/nginx.conf; then
      sudo sed -i '/http {/a \    client_max_body_size 0;' /etc/nginx/nginx.conf
  else
      sudo sed -i 's/client_max_body_size .*/client_max_body_size 0;/' /etc/nginx/nginx.conf
  fi
}


function create_secure_user() {
  echo "[*] Creating a user for Flask app"
  RAND_USER="flask_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin $RAND_USER
  echo "[*] Created user: $RAND_USER"
  RAND_GROUP="grp_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
  sudo groupadd "$RAND_GROUP"
  sudo usermod -g "$RAND_GROUP" "$RAND_USER"
  sudo passwd -l $RAND_USER
}

function set_python_for_flask() {
  echo "[*] Setting up Python virtual environment for Flask..."
  sudo mkdir -p /srv/sixtyshareswhiskey
  sudo chown -R "$RAND_USER":"$RAND_GROUP" /srv/sixtyshareswhiskey
  
  sudo -u "$RAND_USER" bash -c "
    python3 -m venv /srv/sixtyshareswhiskey/venv
    source /srv/sixtyshareswhiskey/venv/bin/activate
    /srv/sixtyshareswhiskey/venv/bin/pip install --upgrade pip flask flask_bcrypt
  "
}


function configure_flask_app_for_daemon_mode() {
  echo "[*] Configuring app.py to listen on 0.0.0.0..."
  sed -i 's/"127\.0\.0\.1"/"0.0.0.0"/g' app.py
}


function update_user_for_systemd_service_file() {
  echo "[*] Changing user in systemd service for Flask app..."
  sed -i "s/User=RAND_USER/User=$RAND_USER/; s/Group=RAND_GROUP/Group=$RAND_GROUP/" sixtyshareswhiskey.service
}

function moving_server_and_frontend_systemd() {
  echo "[*] Moving Flask backend (with anonymous chat)..."
  mv app.py /srv/sixtyshareswhiskey/

  echo "[*] Moving minimal HTML frontend (with upload + chat)..."
  mv index.html style.css script.js /srv/sixtyshareswhiskey/

  echo "[*] Moving systemd service for Flask app..."
  sudo mv sixtyshareswhiskey.service /etc/systemd/system/ 
}

function preparing_cleanup_cronjob() {
  echo "[*] Moving cleanup script..."
  mv cleanup.sh /srv/sixtyshareswhiskey/
  sudo chmod +x /srv/sixtyshareswhiskey/cleanup.sh

  echo "[*] Scheduling cleanup every day at midnight..."
  sudo crontab -l 2>/dev/null > /tmp/mycron || true
  echo "@daily /srv/sixtyshareswhiskey/cleanup.sh" >> /tmp/mycron
  sudo crontab /tmp/mycron
  rm /tmp/mycron
}

function configure_self_destruct_cron_job() {
  return 0
}


function get_ip_address() {
  echo "$(ifconfig wlan0 | grep 'inet ' | awk '{print $2}')"
}


function start_the_service() {
  echo "[*] Enabling and starting services..."
  sudo systemctl daemon-reexec
  sudo systemctl daemon-reload
  sudo systemctl enable sixtyshareswhiskey
  sudo systemctl start sixtyshareswhiskey
  sudo systemctl restart nginx
  if [[ $MODE == "standalone" ]]; then
    sudo systemctl unmask hostapd
    sudo systemctl enable hostapd
    sudo systemctl enable dnsmasq
    sudo systemctl restart hostapd
    sudo systemctl restart dnsmasq
  else
    return 0
  fi
}

function print_success() {
  echo "[✓] SixtySharesWhiskey_fork is ready. Connect to the hotspot and visit https://$(get_ip_address)"
  echo "[*] Keep on keeping on!"
  echo "[*] - AA-2109"
}

# Logic for standalone installation - with hostappd
function standalone_installation_logic() {
  disable_wpa_supplicant_temp
  stop_hostapd_and_dnsmasq
  configure_static_IP
  restart_dhcpd
  configure_dnsmask
  move_hostapd_conf
  configure_hostapd_to_wait_for_dhcpd
}

#logic for daemon installation
function daemon_installation_logic() {
  configure_flask_app_for_daemon_mode
}

# Kamikaze mode is a mode that installs service only for 24 hours. 
# After 24 hours, cron job will remove all traces of service and files uploaded and downloaded.
# Use at your own risk
function kamikaze_installation_logic(){
  configure_self_destruct_cron_job
}

## Main logic for installation
function installation() {
  local mode=$1
  
  validate_parameters
  update_the_system
  install_dependencies_from_internet
  patch_the_host_file
  enable_IPv4_forwarding
  configure_nginx
  prepare_certificates
  move_nginx_conf
  enable_big_uploads
  create_secure_user
  update_user_for_systemd_service_file
  set_python_for_flask

  if [[ $mode == "standalone" ]]; then
    standalone_installation_logic
  fi

  if [[ $mode == "daemon" ]]; then
    daemon_installation_logic
  fi

  if [[ $mode == "kamikaze" ]]; then
    kamikaze_installation_logic
  fi

  if [[ $mode == "gateway" ]]; then
    gateway_installation_logic
  fi

  if [[ $mode == "chat" ]]; then
    chat_installation_logic
  fi

  if [[ $mode == "file-server" ]]; then
    file_server_installation_logic
  fi

  moving_server_and_frontend_systemd
  preparing_cleanup_cronjob
  start_the_service
  print_success

}
## Main function 
installation $MODE
