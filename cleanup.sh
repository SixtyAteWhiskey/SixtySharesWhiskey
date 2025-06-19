#!/bin/bash
cd /srv/sixtyshareswhiskey/uploads/ || exit 1
rm -f *
> /srv/sixtyshareswhiskey/chat.log
HOSTNAME=$(hostname)
sudo openssl req -x509 -newkey rsa:4096 \
  -keyout "/srv/sixtyshareswhiskey/certs/key.pem" \
  -out "/srv/sixtyshareswhiskey/certs/cert.pem" \
  -days 1 \
  -nodes \
  -subj "/C=XX/ST=$HOSTNAME/L=$HOSTNAME/O=$HOSTNAME/OU=$HOSTNAME/CN=127.0.0.1"

sudo chmod 600 "/srv/sixtyshareswhiskey/certs/key.pem"
sudo chmod 644 "/srv/sixtyshareswhiskey/certs/cert.pem"