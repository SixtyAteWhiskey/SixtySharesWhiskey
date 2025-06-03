# SixtySharesWhiskey
A lightweight dead-drop style wireless file transfer

This is a self-contained, anonymous media-sharing hotspot inspired by PirateBox and designed to run on any Raspberry Pi (starting with Raspberry Pi 4) using Ubuntu Server 24.04 LTS.

The script creates a local Wi-Fi network with no internet connection where users can:

- Upload any kind of file (images, videos, docs, etc.)

- Preview image uploads

- See upload progress

- Files are automatically deleted after 24 hours

# Installation

1. Flash Ubuntu Server 24.04.2 LTS to your Raspberry Pi

2. Boot and connect via SSH or terminal

3. Transfer and configure the setup script:

- Edit the WiFi PW by doing the following

A. Transfer the file to your pi using SFTP

OR

B. Use the command ```sudo nano sixtyshareswhiskey_setup.sh``` and then copy and paste in the script contents 

Either way, under "/etc/hostapd/hostapd.conf" edit the wpa_passphrase to a password of your choosing. 

Feel free to change the SSID as well to whatever you want!

Now in nano hit Ctrl + x and save the changes you made.

Now run ```chmod +x sixtyshareswhiskey_setup.sh``` to make the script executeable
And then run ```sudo ./sixtyshareswhiskey_setup.sh``` to run the installer

# After setup:

The Pi will broadcast a Wi-Fi hotspot (by default named SixtySharesWhiskey)

Connect to it, (default wifi pw is "CHANGEME") then open ```http://10.10.10.1``` in your browser!

# Overview

No login or tracking with everything being anonymous and local

Ideal for drops, community share boxes, or field deployments

Files are deleted after 24 hours by cron jobs

