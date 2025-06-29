# SixtySharesWhiskey
A lightweight dead-drop style wireless file transfer

This is a self-contained, anonymous media-sharing hotspot inspired by PirateBox and designed to run on any Raspberry Pi (tested with a RPi02W as of 6/14/25) using Raspberry Pi OS Lite 64 bit.

The script creates a local Wi-Fi network with no internet connection where users can:

- Upload any kind of file (images, videos, docs, etc.)

- Preview image uploads

- See upload progress

- Files are automatically deleted every day at 0000

- New anonymous chat feature! (v1.2.1)

<img width="602" alt="Screenshot 2025-06-04 at 23 58 23" src="https://github.com/user-attachments/assets/c4e95eb2-8d52-469b-a40b-a92c2d34f5f7" />


# To start

1. Flash Raspberry Pi OS Lite 64 bit to your Raspberry Pi

2. Boot and connect via SSH or terminal

3. Transfer and configure the setup script:

# BEFORE YOU TRANSFER THE FILE ENSURE THAT YOU: 
1. OPEN THE SCRIPT IN SOMETHING LIKE NOTEPAD++
2. CHANGE THE COUNTRY CODE TO YOUR COUNTRY
3. CHANGE THE WPA PASSPHRASE
4. (Optional) CHANGE THE SSID
5. VERIFY THAT YOU SAVE THE FILE WITH UNIX LF

![image](https://github.com/user-attachments/assets/38fff35c-15e0-4a19-8319-fedacf2595fd)


![What to change](https://github.com/user-attachments/assets/8ada6058-f5dd-45e7-b60f-f7770d4bb9ec)

# Transferring the file

A. Transfer the file to your pi using SFTP

OR

B. Use the command ```sudo nano sixtyshareswhiskey_setup.sh``` and then copy and paste in the script contents 


Now in nano hit Ctrl + x and save the changes you made.

# Run the script!

Now run ```chmod +x sixtyshareswhiskey_setup.sh``` to make the script executeable

Run ```sudo ./sixtyshareswhiskey_setup.sh``` to run the installer

*********************
***During the install, the script will request that you set your WLAN Country.***

*DO NOT SKIP THIS, the script will not work without it!!*
*********************
# After setup:

The Pi will broadcast a Wi-Fi hotspot (by default named SixtySharesWhiskey)

Connect to it, (default wifi pw is "CHANGEME") then open ```https://10.10.10.1``` in your browser!
Due to usage of self-signed certificates you will see a warning - ignore it.

# Overview

No login or tracking with everything being anonymous and local

Ideal for drops, community share boxes, or field deployments

Files are deleted after 24 hours by cron jobs

