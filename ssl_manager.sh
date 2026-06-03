#!/bin/bash
# ====================================
# SSL 证书管理脚本
# 支持：申请 / 查询 / 自动续期
# 适用：Debian / Ubuntu
# ====================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────
# 工具函数
# ─────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; }
title()   { echo -e "\n${BOLD}${GREEN}========================================${NC}"; \
            echo -e "${BOLD}${GREEN}  $1${NC}"; \
            echo -e "${BOLD}${GREEN}========================================${NC}\n"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 权限运行此脚本"
        echo "  sudo bash ssl_manager.sh"
        exit 1
    fi
}

install_deps() {
    info "检查并安装依赖..."
    apt update -y -qq
    apt install -y curl wget nginx certbot cron dnsutils openssl -qq
    success "依赖安装完成"
}

# ─────────────────────────────────────
# 功能一：申请证书
# ─────────────────────────────────────
apply_cert() {
    title "申请 SSL 证书"

    # 手动输入域名
    while true; do
        read -rp "请输入域名（例如 example.com）: " DOMAIN
        if [ -z "$DOMAIN" ]; then
            error "域名不能为空，请重新输入"
        else
            break
        fi
    done

    info "目标域名: $DOMAIN"

    # 安装依赖
    install_deps

    # 获取服务器公网 IP
    info "获取服务器公网 IP..."
    SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -4 -s --max-time 5 ipv4.icanhazip.com 2>/dev/null)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -4 -s --max-time 5 api.ipify.org 2>/dev/null)

    if [ -z "$SERVER_IP" ]; then
        error "无法获取服务器公网 IP，请检查网络"
        exit 1
    fi
    info "服务器公网 IP: $SERVER_IP"

    # DNS 解析检查
    info "检查域名 DNS 解析..."
    DNS_IPS=$(dig +short "$DOMAIN" A 2>/dev/null)

    if [ -z "$DNS_IPS" ]; then
        error "域名 $DOMAIN 无法解析，请检查 DNS 配置"
        exit 1
    fi

    echo "域名解析到的 IP："
    echo "$DNS_IPS"

    if ! echo "$DNS_IPS" | grep -q "$SERVER_IP"; then
        error "域名未解析到当前服务器（$SERVER_IP）"
        error "请将 $DOMAIN 的 A 记录指向 $SERVER_IP 后重试"
        exit 1
    fi
    success "DNS 解析检查通过"

    # 启动 Nginx 检查 80 端口
    info "检查 80 端口..."
    systemctl enable nginx >/dev/null 2>&1
    systemctl start nginx >/dev/null 2>&1
    sleep 2

    if ! ss -lntp | grep -qE ':80\b'; then
        error "80 端口未监听，请检查 Nginx 或防火墙设置"
        exit 1
    fi
    success "80 端口正常"

    # 停止 Nginx，使用 standalone 模式申请
    systemctl stop nginx >/dev/null 2>&1

    # 申请证书
    info "正在申请 SSL 证书（Let's Encrypt）..."
    certbot certonly \
        --standalone \
        -d "$DOMAIN" \
        --agree-tos \
        --register-unsafely-without-email \
        --non-interactive

    if [ $? -ne 0 ]; then
        error "证书申请失败，常见原因："
        echo "  1. 80 端口被防火墙屏蔽"
        echo "  2. DNS 尚未生效（TTL 未过期）"
        echo "  3. 申请频率超限（每周最多5次）"
        systemctl start nginx >/dev/null 2>&1
        exit 1
    fi
    success "证书申请成功！"

    # 重启 Nginx
    systemctl start nginx >/dev/null 2>&1

    # 配置自动续期（cron）
    setup_auto_renew

    # 显示证书信息
    query_cert "$DOMAIN"
}

# ─────────────────────────────────────
# 功能二：查询证书信息
# ─────────────────────────────────────
query_cert() {
    local DOMAIN="$1"

    if [ -z "$DOMAIN" ]; then
        title "查询证书信息"
        # 列出已有证书
        echo "当前服务器已申请的证书："
        echo ""
        certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:|Certificate Path:" | \
            sed 's/^    /  /'

        echo ""
        read -rp "请输入要查询的域名: " DOMAIN
        if [ -z "$DOMAIN" ]; then
            error "域名不能为空"
            return 1
        fi
    fi

    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

    if [ ! -f "$CERT_PATH" ]; then
        error "未找到域名 $DOMAIN 的证书"
        echo "  证书路径不存在: $CERT_PATH"
        return 1
    fi

    title "证书详情：$DOMAIN"

    # 读取证书信息
    NOT_BEFORE=$(openssl x509 -in "$CERT_PATH" -noout -startdate 2>/dev/null | cut -d= -f2)
    NOT_AFTER=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)

    # 计算剩余天数
    EXPIRE_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRE_EPOCH - NOW_EPOCH) / 86400 ))

    echo -e "  域名         : ${BOLD}$DOMAIN${NC}"
    echo -e "  证书生效时间 : $NOT_BEFORE"
    echo -e "  证书到期时间 : $NOT_AFTER"

    if [ "$DAYS_LEFT" -le 7 ]; then
        echo -e "  剩余天数     : ${RED}${BOLD}$DAYS_LEFT 天（即将到期！）${NC}"
    elif [ "$DAYS_LEFT" -le 30 ]; then
        echo -e "  剩余天数     : ${YELLOW}$DAYS_LEFT 天（建议尽快续期）${NC}"
    else
        echo -e "  剩余天数     : ${GREEN}$DAYS_LEFT 天${NC}"
    fi

    echo ""
    echo -e "  证书路径     : /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    echo -e "  私钥路径     : /etc/letsencrypt/live/$DOMAIN/privkey.pem"
    echo ""
}

# ─────────────────────────────────────
# 功能三：手动续期
# ─────────────────────────────────────
renew_cert() {
    title "手动续期证书"

    # 列出已有证书
    echo "当前服务器已申请的证书："
    certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:" | sed 's/^    /  /'
    echo ""

    read -rp "请输入要续期的域名（留空则续期所有证书）: " DOMAIN

    # 停止 Nginx
    info "停止 Nginx..."
    systemctl stop nginx >/dev/null 2>&1

    if [ -z "$DOMAIN" ]; then
        info "续期所有证书..."
        certbot renew --standalone
    else
        info "续期域名: $DOMAIN"
        certbot certonly \
            --standalone \
            -d "$DOMAIN" \
            --agree-tos \
            --register-unsafely-without-email \
            --non-interactive \
            --force-renewal
    fi

    RESULT=$?

    # 重启 Nginx
    info "重启 Nginx..."
    systemctl start nginx >/dev/null 2>&1

    if [ $RESULT -ne 0 ]; then
        error "续期失败，请检查以上输出"
    else
        success "续期成功！"
        [ -n "$DOMAIN" ] && query_cert "$DOMAIN"
    fi
}

# ─────────────────────────────────────
# 功能四：配置自动续期
# ─────────────────────────────────────
setup_auto_renew() {
    title "配置自动续期"

    # 写入自动续期脚本
    cat > /usr/local/bin/ssl_auto_renew.sh << 'RENEW_SCRIPT'
#!/bin/bash
# SSL 自动续期脚本
LOG="/var/log/ssl_renew.log"
echo "========================================" >> "$LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S') 开始检查证书续期" >> "$LOG"

systemctl stop nginx >> "$LOG" 2>&1
certbot renew --standalone --quiet >> "$LOG" 2>&1
RESULT=$?
systemctl start nginx >> "$LOG" 2>&1

if [ $RESULT -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') 续期检查完成（无需续期或已成功续期）" >> "$LOG"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') 续期失败，请手动检查" >> "$LOG"
fi
RENEW_SCRIPT

    chmod +x /usr/local/bin/ssl_auto_renew.sh

    # 写入 cron 任务（每天凌晨 3:30 检查）
    cat > /etc/cron.d/ssl-auto-renew << 'EOF'
# SSL 证书自动续期（每天 03:30 检查，Let's Encrypt 证书剩余<30天时自动续期）
30 3 * * * root /usr/local/bin/ssl_auto_renew.sh
EOF

    systemctl restart cron >/dev/null 2>&1

    success "自动续期已配置（每天 03:30 自动检查）"
    info "续期日志路径: /var/log/ssl_renew.log"

    # 测试续期（dry-run）
    info "执行续期测试（dry-run，不会真正续期）..."
    certbot renew --dry-run --quiet 2>&1
    if [ $? -eq 0 ]; then
        success "续期测试通过"
    else
        warn "续期测试未通过，请检查证书状态"
    fi
}

# ─────────────────────────────────────
# 主菜单
# ─────────────────────────────────────
main_menu() {
    check_root

    clear
    echo -e "${BOLD}${GREEN}"
    echo "  ╔══════════════════════════════════╗"
    echo "  ║      SSL 证书管理脚本            ║"
    echo "  ║      Debian / Ubuntu             ║"
    echo "  ╚══════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${CYAN}1.${NC} 申请新证书"
    echo -e "  ${CYAN}2.${NC} 查询证书信息"
    echo -e "  ${CYAN}3.${NC} 手动续期证书"
    echo -e "  ${CYAN}4.${NC} 配置自动续期"
    echo -e "  ${CYAN}5.${NC} 退出"
    echo ""
    read -rp "请选择操作 [1-5]: " CHOICE

    case "$CHOICE" in
        1) apply_cert ;;
        2) query_cert ;;
        3) renew_cert ;;
        4) setup_auto_renew ;;
        5) echo "退出"; exit 0 ;;
        *) error "无效选项，请重新运行脚本"; exit 1 ;;
    esac
}

# 入口
main_menu
