#!/bin/bash
# ====================================
# 服务器管理脚本
# 功能：SSL证书 / 系统更新 / BBR / NaiveProxy
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
echo "   服务器管理脚本"
echo "============================="
echo ""
echo "请选择操作："
echo "  1) 申请 SSL 证书"
echo "  2) 查询 SSL 证书"
echo "  3) 续期 SSL 证书"
echo "  4) 系统更新"
echo "  5) 开启 BBR 加速"
echo "  6) 安装 NaiveProxy"
echo ""
read -rp "输入数字 [1-6]: " ACTION

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

# ─── 系统更新 ───
elif [ "$ACTION" = "4" ]; then
    info "更新软件源..."
    apt update -y

    info "升级已安装软件包..."
    apt upgrade -y

    info "清理无用包..."
    apt autoremove -y
    apt autoclean -y

    success "系统更新完成！"

    if [ -f /var/run/reboot-required ]; then
        echo ""
        echo -e "${YELLOW}[!] 系统需要重启才能完成更新${NC}"
        read -rp "现在重启？[y/N]: " REBOOT
        if [ "$REBOOT" = "y" ] || [ "$REBOOT" = "Y" ]; then
            reboot
        else
            echo "请稍后手动执行 reboot"
        fi
    fi

# ─── 开启 BBR ───
elif [ "$ACTION" = "5" ]; then
    CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    CURRENT_QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')

    if [ "$CURRENT_CC" = "bbr" ] && [ "$CURRENT_QDISC" = "fq" ]; then
        success "BBR 已经开启，无需重复操作"
        echo "  拥塞控制: $CURRENT_CC"
        echo "  队列调度: $CURRENT_QDISC"
        exit 0
    fi

    KERNEL=$(uname -r | cut -d. -f1-2 | tr -d '.')
    [ "$KERNEL" -lt 49 ] && error "内核版本过低（需要 4.9+），当前：$(uname -r)"

    info "开启 BBR 加速..."
    cat >> /etc/sysctl.conf << 'EOF'

# BBR 加速
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p >/dev/null 2>&1

    CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    QD=$(sysctl net.core.default_qdisc | awk '{print $3}')

    if [ "$CC" = "bbr" ] && [ "$QD" = "fq" ]; then
        success "BBR 开启成功！"
        echo "  拥塞控制: $CC"
        echo "  队列调度: $QD"
    else
        error "BBR 开启失败，请检查内核是否支持"
    fi

# ─── 安装 NaiveProxy ───
elif [ "$ACTION" = "6" ]; then
    info "安装依赖..."
    apt update -y -qq && apt install -y curl -qq

    info "下载 NaiveProxy 一键脚本..."
    curl -fsSL https://raw.githubusercontent.com/imajeason/nas_tools/main/NaiveProxy/do.sh | bash

    if [ $? -ne 0 ]; then
        error "脚本下载失败，请检查网络连接"
    fi

    success "NaiveProxy 安装脚本执行完成！"
    echo ""
    echo "后续管理命令："
    echo "  执行 naive 进入管理菜单"
    echo "  选择 1 安装 / 更新"
    echo "  选择 7 更新脚本"
    echo ""
    echo "客户端下载："
    echo "  Windows/Linux: https://github.com/klzgrad/naiveproxy/releases"
    echo "  Android:       https://github.com/SagerNet/SagerNet/releases"

else
    error "无效选项，请输入 1-6"
fi

echo ""
