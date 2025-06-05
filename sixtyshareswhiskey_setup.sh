#!/bin/bash

set -e

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

echo "[*] Configuring hostapd..."
sudo mkdir -p /etc/hostapd
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOL
country_code=US       # ← change to your country code
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

# Create a systemd override so hostapd waits for dhcpcd
echo "[*] Ensuring hostapd waits for dhcpcd on boot..."
sudo mkdir -p /etc/systemd/system/hostapd.service.d
sudo tee /etc/systemd/system/hostapd.service.d/override.conf > /dev/null <<EOL
[Unit]
Wants=network-online.target dhcpcd.service
After=network-online.target dhcpcd.service
EOL

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
sudo chmod -R 777 /srv/sixtyshareswhiskey

sudo tee /etc/nginx/sites-available/sixtyshareswhiskey > /dev/null <<EOL
server {
    listen 80 default_server;
    server_name _;

    # Allow large uploads
    client_max_body_size 0;

    root /srv/sixtyshareswhiskey;
    index index.html;

    # Serve index.html and static assets
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Proxy both GET and POST /upload to Flask
    location /upload {
        proxy_pass        http://127.0.0.1:5000;
        proxy_set_header  Host              \$host;
        proxy_set_header  X-Real-IP         \$remote_addr;
        proxy_set_header  X-Forwarded-For   \$proxy_add_x_forwarded_for;
    }

    # Proxy both GET and POST /chat to Flask
    location /chat {
        proxy_pass        http://127.0.0.1:5000;
        proxy_set_header  Host              \$host;
        proxy_set_header  X-Real-IP         \$remote_addr;
        proxy_set_header  X-Forwarded-For   \$proxy_add_x_forwarded_for;
    }

    # Serve the uploads directory as /uploads
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
sudo mkdir -p /srv/sixtyshareswhiskey
sudo chown "$(whoami):$(whoami)" /srv/sixtyshareswhiskey
python3 -m venv /srv/sixtyshareswhiskey/venv
source /srv/sixtyshareswhiskey/venv/bin/activate
/srv/sixtyshareswhiskey/venv/bin/pip install --upgrade pip flask

echo "[*] Creating Flask backend (with anonymous chat)..."
cat <<'EOF' > /srv/sixtyshareswhiskey/app.py
from flask import Flask, request, jsonify
import os
from datetime import datetime

UPLOAD_FOLDER = '/srv/sixtyshareswhiskey/uploads'
CHAT_LOG = '/srv/sixtyshareswhiskey/chat.log'
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

@app.route('/chat', methods=['GET'])
def get_chat():
    messages = []
    if os.path.exists(CHAT_LOG):
        with open(CHAT_LOG, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ts, msg = line.split('|||', 1)
                    messages.append({'timestamp': ts, 'message': msg})
                except ValueError:
                    continue
    return jsonify({'messages': messages})

@app.route('/chat', methods=['POST'])
def post_chat():
    msg = request.form.get('message', '').strip()
    if not msg:
        return "Empty message", 400
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = f"{timestamp}|||{msg}\n"
    with open(CHAT_LOG, 'a', encoding='utf-8') as f:
        f.write(entry)
    return "Message received", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF

echo "[*] Installing minimal HTML frontend (with upload + chat)..."
cat <<'EOF' > /srv/sixtyshareswhiskey/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>SixtySharesWhiskey</title>
  <style>
    body { background: #121212; color: #f0f0f0; font-family: "Segoe UI", sans-serif; display: flex; flex-direction: column; align-items: center; padding: 2rem; }
    h1 { color: #00e0ff; font-size: 2rem; margin-bottom: 1rem; }
    form.upload-box { background: #1e1e1e; border: 2px dashed #444; border-radius: 10px; width: 100%; max-width: 500px; padding: 2rem; text-align: center; transition: border-color 0.3s ease; margin-bottom: 2rem; }
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
    /* Chat styles */
    .chat-container { width: 100%; max-width: 500px; background: #1e1e1e; border: 1px solid #444; border-radius: 8px; padding: 1rem; margin-top: 2rem; }
    .chat-messages { background: #121212; border: 1px solid #333; border-radius: 5px; padding: 1rem; height: 200px; overflow-y: auto; margin-bottom: 1rem; }
    .chat-messages .msg { margin-bottom: 0.5rem; }
    .chat-messages .timestamp { color: #888; font-size: 0.8rem; margin-right: 0.5rem; }
    .chat-form { display: flex; }
    .chat-input { flex: 1; padding: 0.5rem; border: 1px solid #333; border-radius: 5px; background: #121212; color: #f0f0f0; }
    .chat-submit { background: #00e0ff; color: #000; border: none; padding: 0.5rem 1rem; border-radius: 5px; margin-left: 0.5rem; cursor: pointer; }
  </style>
</head>
<body>
  <h1>SixtySharesWhiskey</h1>

  <!-- Upload Form -->
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

  <!-- Anonymous Chat Box -->
  <div class="chat-container">
    <div class="chat-messages" id="chatMessages">
      <!-- Messages will be loaded here -->
    </div>
    <form class="chat-form" id="chatForm">
      <input type="text" id="chatInput" class="chat-input" placeholder="Type your message..." required>
      <button type="submit" class="chat-submit">Send</button>
    </form>
  </div>

  <script>
    // Upload form logic
    const dropArea = document.getElementById("uploadForm");
    const fileInput = document.getElementById("fileElem");
    const messageElem = document.getElementById("message");
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
      messageElem.textContent = "";
      progressBar.style.width = "0%";
      if (fileInput.files.length === 0) {
        messageElem.textContent = "Please select a file first.";
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
          messageElem.textContent = "Upload successful!";
          fileInput.value = "";
        } else {
          messageElem.textContent = "Upload failed. (" + xhr.status + ")";
        }
        progressBar.style.width = "0%";
      };
      xhr.onerror = () => {
        messageElem.textContent = "Upload failed (network error).";
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

    // Chat logic (wrapped to ensure DOM is loaded)
    window.addEventListener('DOMContentLoaded', () => {
      const chatForm = document.getElementById("chatForm");
      const chatInput = document.getElementById("chatInput");
      const chatMessages = document.getElementById("chatMessages");

      chatForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        const text = chatInput.value.trim();
        if (!text) return;
        await fetch('/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: 'message=' + encodeURIComponent(text)
        });
        chatInput.value = '';
        loadMessages();
      });

      async function loadMessages() {
        const resp = await fetch('/chat');
        if (!resp.ok) return;
        const data = await resp.json();
        chatMessages.innerHTML = '';
        data.messages.forEach(entry => {
          const div = document.createElement('div');
          div.classList.add('msg');
          const ts = document.createElement('span');
          ts.classList.add('timestamp');
          ts.textContent = '[' + entry.timestamp + ']';
          const txt = document.createElement('span');
          txt.textContent = entry.message;
          div.appendChild(ts);
          div.appendChild(txt);
          chatMessages.appendChild(div);
        });
        chatMessages.scrollTop = chatMessages.scrollHeight;
      }

      loadMessages();
      setInterval(loadMessages, 5000);
    });
  </script>
</body>
</html>
EOF

echo "[*] Creating cleanup script..."
cat <<'EOF' > /srv/sixtyshareswhiskey/cleanup.sh
#!/bin/bash
cd /srv/sixtyshareswhiskey/uploads/ || exit 1
rm -f *
EOF
sudo chmod +x /srv/sixtyshareswhiskey/cleanup.sh

echo "[*] Scheduling cleanup every day at midnight..."
sudo crontab -l 2>/dev/null > /tmp/mycron || true
echo "@daily /srv/sixtyshareswhiskey/cleanup.sh" >> /tmp/mycron
sudo crontab /tmp/mycron
rm /tmp/mycron

echo "[*] Creating systemd service for Flask app..."
sudo tee /etc/systemd/system/sixtyshareswhiskey.service > /dev/null <<EOL
[Unit]
Description=SixtySharesWhiskey Upload & Chat Server
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
echo "[*] Thank you for installing, God Bless!"
echo "[*] - Sixty"
