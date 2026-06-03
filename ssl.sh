#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear

echo ""
echo "========================================"
echo "     Let's Encrypt SSL Tool"
echo "========================================"
echo ""

read -p "Enter Domain: " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Domain cannot be empty${NC}"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}[1/8] Updating packages...${NC}"

apt update -y

echo ""
echo -e "${YELLOW}[2/8] Installing dependencies...${NC}"

apt install -y \
curl \
wget \
nginx \
certbot \
cron \
dnsutils

echo ""
echo -e "${YELLOW}[3/8] Detecting server IP...${NC}"

SERVER_IP=$(curl -4 -s https://ifconfig.me)

if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -4 -s https://ipv4.icanhazip.com)
fi

DNS_IP=$(dig +short "$DOMAIN" | tail -n1)

echo ""
echo "Domain IP : $DNS_IP"
echo "Server IP : $SERVER_IP"
echo ""

if [ "$DNS_IP" != "$SERVER_IP" ]; then
    echo -e "${RED}ERROR: Domain does not point to this server${NC}"
    exit 1
fi

echo -e "${GREEN}DNS Check Passed${NC}"

echo ""
echo -e "${YELLOW}[4/8] Checking existing certificate...${NC}"

if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo -e "${GREEN}Certificate already exists${NC}"

    openssl x509 \
    -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" \
    -noout -dates

    exit 0
fi

echo ""
echo -e "${YELLOW}[5/8] Starting nginx...${NC}"

systemctl enable nginx >/dev/null 2>&1
systemctl start nginx

sleep 2

if ! ss -lntp | grep -q ":80 "; then
    echo -e "${RED}Port 80 is not listening${NC}"
    exit 1
fi

echo -e "${GREEN}Port 80 OK${NC}"

echo ""
echo -e "${YELLOW}[6/8] Stopping nginx...${NC}"

systemctl stop nginx

echo ""
echo -e "${YELLOW}[7/8] Requesting SSL certificate...${NC}"

certbot certonly \
--standalone \
-d "$DOMAIN" \
--agree-tos \
--register-unsafely-without-email \
--non-interactive

if [ $? -ne 0 ]; then
    echo -e "${RED}Certificate request failed${NC}"
    exit 1
fi

echo -e "${GREEN}Certificate issued successfully${NC}"

echo ""
echo -e "${YELLOW}[8/8] Configuring auto renewal...${NC}"

cat >/etc/cron.d/certbot-renew <<EOF
0 4 * * * root certbot renew --quiet
EOF

systemctl restart cron 2>/dev/null

echo -e "${GREEN}Auto renewal configured${NC}"

echo ""
echo "Testing renewal..."
certbot renew --dry-run

echo ""
echo "========================================"
echo "           COMPLETED"
echo "========================================"
echo ""

echo "Certificate:"
echo "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

echo ""
echo "Private Key:"
echo "/etc/letsencrypt/live/$DOMAIN/privkey.pem"

echo ""
echo "Check Expiry:"
echo "openssl x509 -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem -noout -dates"

echo ""
echo "Manual Renew:"
echo "certbot renew"

echo ""
echo "Renew Test:"
echo "certbot renew --dry-run"

echo ""
echo "Done."
