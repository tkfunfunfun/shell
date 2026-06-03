#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear

echo ""
echo "========================================"
echo "      Let's Encrypt SSL 一键脚本"
echo "========================================"
echo ""

read -p "请输入域名: " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}域名不能为空${NC}"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}[1/8] 更新软件源...${NC}"

apt update -y

echo ""
echo -e "${YELLOW}[2/8] 安装依赖...${NC}"

apt install -y \
curl \
wget \
nginx \
certbot \
cron \
dnsutils

echo ""
echo -e "${YELLOW}[3/8] 获取服务器IP...${NC}"

SERVER_IP=$(curl -4 -s ifconfig.me)

if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -4 -s ipv4.icanhazip.com)
fi

DNS_IP=$(dig +short $DOMAIN | tail -n1)

echo ""
echo "域名解析IP : $DNS_IP"
echo "服务器公网IP : $SERVER_IP"
echo ""

if [ "$DNS_IP" != "$SERVER_IP" ]; then
    echo -e "${RED}错误：域名未解析到当前服务器${NC}"
    exit 1
fi

echo -e "${GREEN}DNS检查通过${NC}"

echo ""
echo -e "${YELLOW}[4/8] 检查证书是否已存在...${NC}"

if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo -e "${GREEN}证书已存在${NC}"

    openssl x509 \
    -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem \
    -noout -dates

    exit 0
fi

echo ""
echo -e "${YELLOW}[5/8] 启动 Nginx...${NC}"

systemctl enable nginx >/dev/null 2>&1
systemctl start nginx

sleep 2

if ! ss -lntp | grep -q ":80 "; then
    echo -e "${RED}80端口监听失败${NC}"
    exit 1
fi

echo -e "${GREEN}80端口正常${NC}"

echo ""
echo -e "${YELLOW}[6/8] 停止 Nginx 申请证书...${NC}"

systemctl stop nginx

echo ""
echo -e "${YELLOW}[7/8] 申请SSL证书...${NC}"

certbot certonly \
--standalone \
-d $DOMAIN \
--agree-tos \
--register-unsafely-without-email \
--non-interactive

if [ $? -ne 0 ]; then
    echo -e "${RED}证书申请失败${NC}"
    exit 1
fi

echo -e "${GREEN}证书申请成功${NC}"

echo ""
echo -e "${YELLOW}[8/8] 配置自动续期...${NC}"

cat >/etc/cron.d/certbot-renew <<EOF
0 4 * * * root certbot renew --quiet
EOF

systemctl restart cron

echo -e "${GREEN}自动续期配置完成${NC}"

echo ""
echo "测试续期功能..."
certbot renew --dry-run

echo ""
echo "========================================"
echo "           SSL申请完成"
echo "========================================"
echo ""

echo "证书路径："
echo "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

echo ""
echo "私钥路径："
echo "/etc/letsencrypt/live/$DOMAIN/privkey.pem"

echo ""
echo "查看证书有效期："
echo "openssl x509 -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem -noout -dates"

echo ""
echo "手动续期："
echo "certbot renew"

echo ""
echo "测试续期："
echo "certbot renew --dry-run"

echo ""
echo "完成。"
