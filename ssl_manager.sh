#!/bin/bash
# ====================================
# SSL 证书管理脚本 - 简化版
# Debian / Ubuntu
# ====================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}[✔] $1${NC}"; }
error()   { echo -e "${RED}[✘] $1${NC}"; exit 1; }
info()    { echo -e "${YELLOW}[*] $1${NC}"; }

# 检查 root
[ "$EUID" -ne 0 ] && error "请使用 root 权限运行: sudo bash ssl_manager.sh"

echo ""
echo "============================="
echo "   SSL 证书管理脚本"
echo "============================="
echo ""
echo "请选择操作："
echo "  1) 申请证书"
echo "  2) 查询证书"
echo "  3) 续期证书"
echo ""
read -rp "输入数字 [1/2/3]: " ACTION

# ─── 申请证书 ───
if [ "$ACTION" = "1" ]; then
    read -rp "请输入域名: " DOMAIN
    [ -z "$DOMAIN" ] && error "域名不能为空"

    info "安装依赖..."
    apt update -y -qq && apt install -y curl nginx certbot dnsutils -qq

    info "获取服务器 IP..."
    SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me)
    DNS_IP=$(dig +short "$DOMAIN" A | tail -n1)

    echo "服务器 IP : $SERVER_IP"
    echo "域名解析  : $DNS_IP"

    [ "$DNS_IP" != "$SERVER_IP" ] && error "域名未解析到当前服务器，请检查 DNS"

    info "启动 Nginx..."
    systemctl start nginx && sleep 2
    ss -lntp | grep -qE ':80\b' || error "80 端口未监听"

    info "申请证书..."
    systemctl stop nginx
    certbot certonly --standalone -d "$DOMAIN" \
        --agree-tos --register-unsafely-without-email --non-interactive
    [ $? -ne 0 ] && { systemctl start nginx; error "证书申请失败"; }
    systemctl start nginx

    # 自动续期
    cat > /usr/local/bin/ssl_renew.sh << 'EOF'
#!/bin/bash
systemctl stop nginx
certbot renew --standalone --quiet >> /var/log/ssl_renew.log 2>&1
systemctl start nginx
EOF
    chmod +x /usr/local/bin/ssl_renew.sh
    echo "30 3 * * * root /usr/local/bin/ssl_renew.sh" > /etc/cron.d/ssl-renew
    systemctl restart cron

    success "申请成功！自动续期已配置（每天 03:30）"
    echo ""
    echo "证书路径: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    echo "私钥路径: /etc/letsencrypt/live/$DOMAIN/privkey.pem"

# ─── 查询证书 ───
elif [ "$ACTION" = "2" ]; then
    read -rp "请输入域名: " DOMAIN
    CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    [ ! -f "$CERT" ] && error "未找到 $DOMAIN 的证书"

    NOT_AFTER=$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)
    DAYS=$(( ( $(date -d "$NOT_AFTER" +%s) - $(date +%s) ) / 86400 ))

    echo ""
    echo "域名    : $DOMAIN"
    echo "到期时间: $NOT_AFTER"
    if [ "$DAYS" -le 7 ]; then
        echo -e "剩余天数: ${RED}${DAYS} 天（即将到期！）${NC}"
    elif [ "$DAYS" -le 30 ]; then
        echo -e "剩余天数: ${YELLOW}${DAYS} 天（建议续期）${NC}"
    else
        echo -e "剩余天数: ${GREEN}${DAYS} 天${NC}"
    fi

# ─── 续期证书 ───
elif [ "$ACTION" = "3" ]; then
    read -rp "请输入域名（留空续期所有）: " DOMAIN
    info "停止 Nginx..."
    systemctl stop nginx

    if [ -z "$DOMAIN" ]; then
        certbot renew --standalone
    else
        certbot certonly --standalone -d "$DOMAIN" \
            --agree-tos --register-unsafely-without-email \
            --non-interactive --force-renewal
    fi

    systemctl start nginx
    success "续期完成"

else
    error "无效选项"
fi
