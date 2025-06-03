#!/bin/bash

set -e

echo "[*] Updating system..."
sudo apt update && sudo apt upgrade -y

echo "[*] Installing required packages..."
sudo apt install -y hostapd dnsmasq nginx python3 python3-pip python3-venv git netplan.io

echo "[*] Disabling systemd-resolved and configuring DNS..."
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
sudo rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf

echo "[*] Patching /etc/hosts for hostname resolution..."
HOSTNAME=$(hostname)
if ! grep -q "127.0.1.1" /etc/hosts; then
    echo "127.0.1.1       $HOSTNAME" | sudo tee -a /etc/hosts
else
    sudo sed -i "s/^127.0.1.1.*/127.0.1.1       $HOSTNAME/" /etc/hosts
fi

echo "[*] Stopping interfering services..."
sudo systemctl stop hostapd || true
sudo systemctl stop dnsmasq || true

echo "[*] Configuring static IP for wlan0 via netplan..."
sudo tee /etc/netplan/99-sixtyshareswhiskey.yaml > /dev/null <<EOL
network:
  version: 2
  renderer: networkd
  ethernets:
    wlan0:
      dhcp4: no
      addresses: [10.10.10.1/24]
EOL

sudo chmod 600 /etc/netplan/99-sixtyshareswhiskey.yaml
sudo netplan apply

echo "[*] Configuring dnsmasq..."
sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig || true
sudo tee /etc/dnsmasq.conf > /dev/null <<EOL
interface=wlan0
dhcp-range=10.10.10.10,10.10.10.100,24h
address=/#/10.10.10.1
EOL

echo "[*] Configuring hostapd..."
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOL
interface=wlan0
driver=nl80211
ssid=SixtySharesWhiskey
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=CHANGEME
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

EOL

sudo tee /etc/default/hostapd > /dev/null <<EOL
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOL

echo "[*] Enabling IP forwarding..."
sudo tee -a /etc/sysctl.conf > /dev/null <<EOL
net.ipv4.ip_forward=1
EOL
sudo sysctl -p

echo "[*] Setting up NGINX for web GUI..."
sudo mkdir -p /srv/sixtyshareswhiskey/uploads
sudo chmod -R 777 /srv/sixtyshareswhiskey/uploads

sudo tee /etc/nginx/sites-available/sixtyshareswhiskey > /dev/null <<EOL
server {
    listen 80 default_server;
    server_name _;

    client_max_body_size 0;

    location / {
        root /srv/sixtyshareswhiskey;
        index index.html;
    }

    location /upload {
        proxy_pass http://localhost:5000/upload;
    }

    location /uploads {
        alias /srv/sixtyshareswhiskey/uploads;
        autoindex on;
    }
}
EOL

sudo ln -sf /etc/nginx/sites-available/sixtyshareswhiskey /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

echo "[*] Patching nginx.conf for global client_max_body_size override..."
if ! grep -q "client_max_body_size" /etc/nginx/nginx.conf; then
    sudo sed -i '/http {/a \    client_max_body_size 0;' /etc/nginx/nginx.conf
else
    sudo sed -i 's/client_max_body_size .*/client_max_body_size 0;/' /etc/nginx/nginx.conf
fi

sudo systemctl restart nginx

echo "[*] Setting up Python virtual environment for Flask..."
python3 -m venv /srv/sixtyshareswhiskey/venv
source /srv/sixtyshareswhiskey/venv/bin/activate
/srv/sixtyshareswhiskey/venv/bin/pip install flask

echo "[*] Creating corrected Flask backend..."
cat <<EOF > /srv/sixtyshareswhiskey/app.py
from flask import Flask, request
import os
from datetime import datetime

UPLOAD_FOLDER = '/srv/sixtyshareswhiskey/uploads'
app = Flask(__name__)
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER

@app.route('/upload', methods=['POST'])
def upload_file():
    if 'file' not in request.files:
        return "No file part", 400
    file = request.files['file']
    if file.filename == '':
        return "No selected file", 400
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    filename = f"{timestamp}_{file.filename}"
    file.save(os.path.join(app.config['UPLOAD_FOLDER'], filename))
    return "Upload successful", 200

app.run(host="0.0.0.0", port=5000)
EOF

echo "[*] Installing minimal HTML frontend..."
cat <<EOF > /srv/sixtyshareswhiskey/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>SixtySharesWhiskey</title>
  <style>
    body { background: #121212; color: #f0f0f0; font-family: "Segoe UI", sans-serif; display: flex; flex-direction: column; align-items: center; padding: 2rem; }
    h1 { color: #00e0ff; font-size: 2rem; margin-bottom: 1rem; }
    form.upload-box { background: #1e1e1e; border: 2px dashed #444; border-radius: 10px; width: 100%; max-width: 500px; padding: 2rem; text-align: center; transition: border-color 0.3s ease; }
    .upload-box.dragover { border-color: #00e0ff; }
    input[type="file"] { display: none; }
    .browse-label { color: #00e0ff; cursor: pointer; }
    .submit-btn { background: #00e0ff; color: #000; border: none; padding: 0.6rem 1.5rem; border-radius: 5px; font-weight: bold; font-size: 1rem; margin-top: 1rem; cursor: pointer; }
    .link { margin-top: 1.5rem; }
    .link a { color: #90caf9; text-decoration: none; }
    .link a:hover { text-decoration: underline; }
    .message { margin-top: 1rem; font-size: 0.95rem; }
    #preview { margin-top: 1rem; }
    #preview img { max-width: 100px; max-height: 100px; margin: 0.5rem; border-radius: 5px; }
    .progress { width: 100%; background: #333; border-radius: 10px; margin-top: 1rem; height: 20px; overflow: hidden; }
    .progress-bar { height: 100%; width: 0%; background: #00e0ff; transition: width 0.3s ease; }
  </style>
</head>
<body>
  <h1>SixtySharesWhiskey</h1>
  <form class="upload-box" id="uploadForm" method="post" action="/upload" enctype="multipart/form-data">
    <p>Drag and drop a file here</p>
    <p>or <label for="fileElem" class="browse-label">browse</label></p>
    <input type="file" name="file" id="fileElem" required>
    <button class="submit-btn" type="submit">Upload</button>
    <div class="progress"><div class="progress-bar" id="progressBar"></div></div>
    <div class="message" id="message"></div>
    <div id="preview"></div>
  </form>
  <div class="link"><p><a href="/uploads">View Uploaded Files</a></p></div>
  <script>
    const dropArea = document.getElementById("uploadForm");
    const fileInput = document.getElementById("fileElem");
    const message = document.getElementById("message");
    const preview = document.getElementById("preview");
    const progressBar = document.getElementById("progressBar");
    dropArea.addEventListener("dragover", (e) => { e.preventDefault(); dropArea.classList.add("dragover"); });
    dropArea.addEventListener("dragleave", () => { dropArea.classList.remove("dragover"); });
    dropArea.addEventListener("drop", (e) => {
      e.preventDefault();
      dropArea.classList.remove("dragover");
      if (e.dataTransfer.files.length > 0) {
        fileInput.files = e.dataTransfer.files;
        showPreview(e.dataTransfer.files[0]);
      }
    });
    fileInput.addEventListener("change", () => {
      if (fileInput.files.length > 0) {
        showPreview(fileInput.files[0]);
      }
    });
    dropArea.addEventListener("submit", (e) => {
      e.preventDefault();
      message.textContent = "";
      progressBar.style.width = "0%";
      if (fileInput.files.length === 0) {
        message.textContent = "Please select a file first.";
        return;
      }
      const formData = new FormData();
      formData.append("file", fileInput.files[0]);
      const xhr = new XMLHttpRequest();
      xhr.open("POST", "/upload", true);
      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable) {
          const percent = (e.loaded / e.total) * 100;
          progressBar.style.width = percent + "%";
        }
      };
      xhr.onload = () => {
        if (xhr.status === 200) {
          message.textContent = "Upload successful!";
          fileInput.value = "";
        } else {
          message.textContent = "Upload failed. (" + xhr.status + ")";
        }
        progressBar.style.width = "0%";
      };
      xhr.onerror = () => {
        message.textContent = "Upload failed (network error).";
        progressBar.style.width = "0%";
      };
      xhr.send(formData);
    });
    function showPreview(file) {
      preview.innerHTML = "";
      if (file.type.startsWith("image/")) {
        const reader = new FileReader();
        reader.onload = (e) => {
          const img = document.createElement("img");
          img.src = e.target.result;
          preview.appendChild(img);
        };
        reader.readAsDataURL(file);
      }
    }
  </script>
</body>
</html>
EOF

echo "[*] Creating cleanup script..."
cat <<EOF > /srv/sixtyshareswhiskey/cleanup.sh
#!/bin/bash
find /srv/sixtyshareswhiskey/uploads/ -type f -mmin +1440 -delete
EOF
chmod +x /srv/sixtyshareswhiskey/cleanup.sh

echo "[*] Scheduling cleanup every hour..."
(crontab -l 2>/dev/null; echo "0 * * * * /srv/sixtyshareswhiskey/cleanup.sh") | crontab -

echo "[*] Creating systemd service for Flask app..."
sudo tee /etc/systemd/system/sixtyshareswhiskey.service > /dev/null <<EOL
[Unit]
Description=SixtySharesWhiskey Upload Server
After=network.target

[Service]
ExecStart=/srv/sixtyshareswhiskey/venv/bin/python /srv/sixtyshareswhiskey/app.py
WorkingDirectory=/srv/sixtyshareswhiskey
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable sixtyshareswhiskey
sudo systemctl start sixtyshareswhiskey

echo "[*] Enabling and starting services..."
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq
sudo systemctl restart hostapd
sudo systemctl restart dnsmasq

echo "[✓] SixtySharesWhiskey is ready. Connect to the hotspot and visit http://10.10.10.1"
echo "Thank you for installing, God Bless!"
echo "- Sixty"
