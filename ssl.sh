#!/usr/bin/env bash

echo "================================="
echo "     Let's Encrypt SSL Tool"
echo "================================="
echo

read -p "Enter Domain: " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo "Domain cannot be empty"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

echo
echo "[1/6] Updating packages..."
apt update -y

echo
echo "[2/6] Installing dependencies..."
apt install -y curl wget nginx certbot cron dnsutils

SERVER_IP=$(curl -4 -s ifconfig.me)
DNS_IP=$(dig +short $DOMAIN | tail -n1)

echo
echo "Domain IP : $DNS_IP"
echo "Server IP : $SERVER_IP"

if [ "$DNS_IP" != "$SERVER_IP" ]; then
    echo
    echo "ERROR: Domain does not point to this server"
    exit 1
fi

echo
echo "[3/6] Starting nginx..."
systemctl enable nginx
systemctl restart nginx

echo
echo "[4/6] Stopping nginx for certbot..."
systemctl stop nginx

echo
echo "[5/6] Applying SSL certificate..."

certbot certonly \
--standalone \
-d $DOMAIN \
--agree-tos \
--register-unsafely-without-email \
--non-interactive

if [ $? -ne 0 ]; then
    echo
    echo "SSL apply failed"
    exit 1
fi

echo
echo "[6/6] Setting auto renewal..."

cat > /root/renew_ssl.sh << EOF
#!/bin/bash
systemctl stop nginx
certbot renew --quiet
systemctl start nginx
EOF

chmod +x /root/renew_ssl.sh

(crontab -l 2>/dev/null; echo "0 3 * * * /root/renew_ssl.sh") | crontab -

systemctl start nginx

echo
echo "================================="
echo "SSL SUCCESS"
echo "================================="
echo
echo "Certificate:"
echo "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo
echo "Private Key:"
echo "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo
echo "Auto renewal enabled"
echo
