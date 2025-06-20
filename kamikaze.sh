#!/bin/bash

sudo systemctl stop hostapd || true
sudo systemctl stop dnsmasq || true
sudo systemctl stop nginx || true
sudo systemctl disable hostapd || true
sudo systemctl disable dnsmasq || true
cd /srv/sixtyshareswhiskey/uploads/ || exit 1
rm -f /srv/sixtyshareswhiskey/
sudo apt purge -y hostapd dnsmasq nginx
sudo apt autoremove -y
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
rm -rf /etc/systemd/system/sixtyshareswhiskey.service
rm -rf /etc/nginx/nginx.conf
rm -rf /etc/nginx/sites-available/sixtyshareswhiskey
rm -rf /etc/systemd/system/hostapd.service.d/override.conf
rm -rf /etc/hostapd/hostapd.conf
rm -rf /etc/dnsmasq.conf
rm -rf /etc/dhcpcd.conf
sudo sed -i '/^net\.ipv4\.ip_forward=1$/d' /etc/sysctl.conf
sudo sysctl -p || true
sudo sed -i '/^127.0.1.1[[:space:]]\+'$(hostname)'$/d' /etc/hosts
sudo systemctl enable wpa_supplicant.service || true
sudo systemctl start wpa_supplicant.service || true
