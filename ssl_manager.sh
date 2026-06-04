#!/bin/bash
# ====================================
# 服务器管理脚本
# 功能：SSL证书 / 系统更新 / BBR / NaiveProxy
# Debian / Ubuntu
# ====================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

success() { echo -e "${GREEN}${BOLD} ✔  $1${NC}"; }
error()   { echo -e "${RED}${BOLD} ✘  $1${NC}"; exit 1; }
info()    { echo -e "${CYAN} ➤  $1${NC}"; }
warn()    { echo -e "${YELLOW} !  $1${NC}"; }

# 检查 root
[ "$EUID" -ne 0 ] && error "请使用 root 权限运行: sudo bash ssl_manager.sh"

clear
echo ""
echo -e "${CYAN}${BOLD}  ╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${WHITE}★  服务器一键管理脚本  ★${CYAN}${BOLD}              ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${DIM}${WHITE}Debian / Ubuntu                     ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ╠════════════════════════════════════════╣${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${GREEN}${BOLD}[1]${NC}${WHITE} 申请 SSL 证书                  ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${GREEN}${BOLD}[2]${NC}${WHITE} 查询 SSL 证书                  ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${GREEN}${BOLD}[3]${NC}${WHITE} 续期 SSL 证书                  ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${YELLOW}${BOLD}[4]${NC}${WHITE} 系统更新                       ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${YELLOW}${BOLD}[5]${NC}${WHITE} 开启 BBR 加速                  ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${MAGENTA}${BOLD}[6]${NC}${WHITE} 安装 NaiveProxy                ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${RED}${BOLD}[0]${NC}${WHITE} 退出                           ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ╚════════════════════════════════════════╝${NC}"
echo ""
read -rp "$(echo -e ${WHITE}${BOLD}"  请输入选项: "${NC})" ACTION
echo ""

# ─── 申请证书 ───
if [ "$ACTION" = "1" ]; then
    echo -e "${GREEN}${BOLD}  ── 申请 SSL 证书 ──${NC}\n"
    read -rp "$(echo -e ${WHITE}"  请输入域名: "${NC})" DOMAIN
    [ -z "$DOMAIN" ] && error "域名不能为空"

    info "安装依赖..."
    apt update -y -qq && apt install -y curl nginx certbot dnsutils -qq

    info "获取服务器 IP..."
    SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me)
    DNS_IP=$(dig +short "$DOMAIN" A | tail -n1)

    echo -e "  ${DIM}服务器 IP : ${WHITE}$SERVER_IP${NC}"
    echo -e "  ${DIM}域名解析  : ${WHITE}$DNS_IP${NC}"

    [ "$DNS_IP" != "$SERVER_IP" ] && error "域名未解析到当前服务器，请检查 DNS"
    success "DNS 检查通过"

    info "启动 Nginx..."
    systemctl start nginx && sleep 2
    ss -lntp | grep -qE ':80\b' || error "80 端口未监听"
    success "80 端口正常"

    info "申请证书中..."
    systemctl stop nginx
    certbot certonly --standalone -d "$DOMAIN" \
        --agree-tos --register-unsafely-without-email --non-interactive
    [ $? -ne 0 ] && { systemctl start nginx; error "证书申请失败"; }
    systemctl start nginx

    cat > /usr/local/bin/ssl_renew.sh << 'EOF'
#!/bin/bash
systemctl stop nginx
certbot renew --standalone --quiet >> /var/log/ssl_renew.log 2>&1
systemctl start nginx
EOF
    chmod +x /usr/local/bin/ssl_renew.sh
    echo "30 3 * * * root /usr/local/bin/ssl_renew.sh" > /etc/cron.d/ssl-renew
    systemctl restart cron

    echo ""
    echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}  ║   ✔  证书申请成功！                  ║${NC}"
    echo -e "${GREEN}${BOLD}  ╠══════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}  ║${NC}  证书路径:                            ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}  ║${NC}  ${WHITE}/etc/letsencrypt/live/$DOMAIN/${NC}  ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}  ║${NC}  fullchain.pem  /  privkey.pem        ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}  ║${NC}                                       ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}  ║${NC}  自动续期: 每天 ${YELLOW}03:30${NC} 自动检查        ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════╝${NC}"

# ─── 查询证书 ───
elif [ "$ACTION" = "2" ]; then
    echo -e "${GREEN}${BOLD}  ── 查询 SSL 证书 ──${NC}\n"
    read -rp "$(echo -e ${WHITE}"  请输入域名: "${NC})" DOMAIN
    CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    [ ! -f "$CERT" ] && error "未找到 $DOMAIN 的证书"

    NOT_AFTER=$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)
    DAYS=$(( ( $(date -d "$NOT_AFTER" +%s) - $(date +%s) ) / 86400 ))

    if [ "$DAYS" -le 7 ]; then
        DAY_COLOR="${RED}${BOLD}"
        DAY_TIP="（即将到期！）"
    elif [ "$DAYS" -le 30 ]; then
        DAY_COLOR="${YELLOW}${BOLD}"
        DAY_TIP="（建议续期）"
    else
        DAY_COLOR="${GREEN}${BOLD}"
        DAY_TIP=""
    fi

    echo ""
    echo -e "${CYAN}${BOLD}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}  ║   证书信息                           ║${NC}"
    echo -e "${CYAN}${BOLD}  ╠══════════════════════════════════════╣${NC}"
    echo -e "${CYAN}${BOLD}  ║${NC}  域名    : ${WHITE}${BOLD}$DOMAIN${NC}"
    echo -e "${CYAN}${BOLD}  ║${NC}  到期时间: ${WHITE}$NOT_AFTER${NC}"
    echo -e "${CYAN}${BOLD}  ║${NC}  剩余天数: ${DAY_COLOR}${DAYS} 天 ${DAY_TIP}${NC}"
    echo -e "${CYAN}${BOLD}  ╚══════════════════════════════════════╝${NC}"

# ─── 续期证书 ───
elif [ "$ACTION" = "3" ]; then
    echo -e "${GREEN}${BOLD}  ── 续期 SSL 证书 ──${NC}\n"
    read -rp "$(echo -e ${WHITE}"  请输入域名（留空续期所有）: "${NC})" DOMAIN
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
    echo -e "${YELLOW}${BOLD}  ── 系统更新 ──${NC}\n"
    info "更新软件源..."
    apt update -y
    info "升级软件包..."
    apt upgrade -y
    info "清理无用包..."
    apt autoremove -y && apt autoclean -y
    success "系统更新完成！"

    if [ -f /var/run/reboot-required ]; then
        echo ""
        warn "系统需要重启才能完成更新"
        read -rp "$(echo -e ${WHITE}"  现在重启？[y/N]: "${NC})" REBOOT
        if [ "$REBOOT" = "y" ] || [ "$REBOOT" = "Y" ]; then
            reboot
        else
            warn "请稍后手动执行 reboot"
        fi
    fi

# ─── 开启 BBR ───
elif [ "$ACTION" = "5" ]; then
    echo -e "${YELLOW}${BOLD}  ── 开启 BBR 加速 ──${NC}\n"

    CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    CURRENT_QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')

    if [ "$CURRENT_CC" = "bbr" ] && [ "$CURRENT_QDISC" = "fq" ]; then
        success "BBR 已开启，无需重复操作"
        echo -e "  拥塞控制: ${GREEN}$CURRENT_CC${NC}"
        echo -e "  队列调度: ${GREEN}$CURRENT_QDISC${NC}"
        exit 0
    fi

    KERNEL=$(uname -r | cut -d. -f1-2 | tr -d '.')
    [ "$KERNEL" -lt 49 ] && error "内核版本过低（需要 4.9+），当前：$(uname -r)"

    info "写入 BBR 配置..."
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
        echo -e "  拥塞控制: ${GREEN}${BOLD}$CC${NC}"
        echo -e "  队列调度: ${GREEN}${BOLD}$QD${NC}"
    else
        error "BBR 开启失败，请检查内核是否支持"
    fi

# ─── 安装 NaiveProxy ───
elif [ "$ACTION" = "6" ]; then
    echo -e "${MAGENTA}${BOLD}  ── 安装 NaiveProxy ──${NC}\n"
    info "安装依赖..."
    apt update -y -qq && apt install -y curl -qq

    info "下载并执行 NaiveProxy 一键脚本..."
    curl -fsSL https://raw.githubusercontent.com/imajeason/nas_tools/main/NaiveProxy/do.sh | bash
    [ $? -ne 0 ] && error "脚本下载失败，请检查网络连接"

    success "NaiveProxy 安装完成！"
    echo ""
    echo -e "  ${WHITE}后续管理: 执行 ${CYAN}${BOLD}naive${NC}${WHITE} 进入管理菜单${NC}"
    echo -e "  ${WHITE}Windows : ${CYAN}https://github.com/klzgrad/naiveproxy/releases${NC}"
    echo -e "  ${WHITE}Android : ${CYAN}https://github.com/SagerNet/SagerNet/releases${NC}"

# ─── 退出 ───
elif [ "$ACTION" = "0" ]; then
    echo -e "${DIM}  再见！${NC}\n"
    exit 0

else
    error "无效选项，请输入 0-6"
fi

echo ""
