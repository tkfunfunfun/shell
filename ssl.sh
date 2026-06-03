#!/bin/bash

read -p "请输入域名: " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo "域名不能为空"
    exit 1
fi

echo "域名: $DOMAIN"

apt update -y
apt install -y curl wget nginx certbot cron dnsutils

SERVER_IP=$(curl -4 -s ifconfig.me)
DNS_IP=$(dig +short $DOMAIN | tail -n1)

echo "域名IP: $DNS_IP"
echo "服务器IP: $SERVER_IP"

if [ "$DNS_IP" != "$SERVER_IP" ]; then
    echo "错误：域名未解析到当前服务器"
    exit 1
fi

systemctl enable nginx
systemctl start nginx

systemctl stop nginx

certbot certonly \
--standalone \
-d $DOMAIN \
--agree-tos \
--register-unsafely-without-email \
--non-interactive

echo ""
echo "证书路径："
echo "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

echo ""
echo "私钥路径："
echo "/etc/letsencrypt/live/$DOMAIN/privkey.pem"

echo ""
echo "测试续期："
echo "certbot renew --dry-run"
