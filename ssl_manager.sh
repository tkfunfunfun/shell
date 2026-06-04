#!/bin/bash
# ====================================
# 综合管理脚本
# SSL 证书管理 + NaiveProxy 管理
# Debian / Ubuntu
# ====================================

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

_red()     { echo -e "${red}$*${none}"; }
_green()   { echo -e "${green}$*${none}"; }
_yellow()  { echo -e "${yellow}$*${none}"; }
_cyan()    { echo -e "${cyan}$*${none}"; }
success()  { echo -e "${green}[✔] $*${none}"; }
error()    { echo -e "${red}[✘] $*${none}"; }
info()     { echo -e "${yellow}[*] $*${none}"; }
pause()    { read -rsp "$(echo -e "按 ${green}Enter${none} 继续，或 ${red}Ctrl+C${none} 取消...")" -d $'\n'; echo; }

# Root 检查
[[ $(id -u) != 0 ]] && _red "\n请使用 root 用户运行此脚本\n" && exit 1

# 系统架构检测
sys_bit=$(uname -m)
case $sys_bit in
    'amd64'|x86_64)   caddy_arch="amd64" ;;
    *aarch64*|*armv8*) caddy_arch="arm64" ;;
    *) _red "不支持的系统架构" && exit 1 ;;
esac

# 包管理器检测
if [[ $(command -v apt-get) ]]; then
    cmd="apt-get"
elif [[ $(command -v yum) ]]; then
    cmd="yum"
else
    _red "不支持的系统" && exit 1
fi

systemd=true
uuid=$(cat /proc/sys/kernel/random/uuid)

do_service() { systemctl $1 $2 $3; }

get_ip() {
    ipv4=$(curl -s --max-time 5 https://ipinfo.io/ip)
    [[ -z $ipv4 ]] && ipv4=$(curl -s --max-time 5 https://api.ipify.org)
    [[ -z $ipv4 ]] && ipv4=$(curl -s --max-time 5 ifconfig.me)
    ipv6=$(ip a | grep inet6 | grep global | awk '{print $2}' | awk -F'/' '{print $1}')
    ip_all="$ipv4 $ipv6"
}

# ══════════════════════════════════════
#   SSL 证书管理
# ══════════════════════════════════════

ssl_apply() {
    echo
    info "=== 申请 SSL 证书 ==="
    read -rp "请输入域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && error "域名不能为空" && return 1

    info "安装依赖..."
    $cmd update -y -qq && $cmd install -y curl nginx certbot dnsutils openssl -qq

    info "获取服务器 IP..."
    get_ip
    DNS_IP=$(dig +short "$DOMAIN" A | tail -n1)
    echo "服务器 IP : $ipv4"
    echo "域名解析  : $DNS_IP"

    if ! echo "$ipv4" | grep -q "$DNS_IP" && [[ "$DNS_IP" != "$ipv4" ]]; then
        error "域名未解析到当前服务器（$ipv4），请检查 DNS"
        return 1
    fi

    info "检查 80 端口..."
    do_service start nginx >/dev/null 2>&1 && sleep 2
    if ! ss -lntp | grep -qE ':80\b'; then
        error "80 端口未监听，请检查 Nginx 或防火墙"
        return 1
    fi
    success "80 端口正常"

    info "申请证书..."
    do_service stop nginx >/dev/null 2>&1
    certbot certonly --standalone -d "$DOMAIN" \
        --agree-tos --register-unsafely-without-email --non-interactive
    if [[ $? -ne 0 ]]; then
        do_service start nginx >/dev/null 2>&1
        error "证书申请失败"
        return 1
    fi
    do_service start nginx >/dev/null 2>&1

    ssl_setup_cron
    success "证书申请成功！"
    echo
    echo "证书路径: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    echo "私钥路径: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
}

ssl_query() {
    echo
    info "=== 查询证书信息 ==="
    echo "当前已申请的证书："
    certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:" | sed 's/^    /  /'
    echo
    read -rp "请输入要查询的域名: " DOMAIN
    CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    [[ ! -f "$CERT" ]] && error "未找到 $DOMAIN 的证书" && return 1

    NOT_AFTER=$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)
    DAYS=$(( ( $(date -d "$NOT_AFTER" +%s) - $(date +%s) ) / 86400 ))

    echo
    echo "域名    : $DOMAIN"
    echo "到期时间: $NOT_AFTER"
    if [[ $DAYS -le 7 ]]; then
        echo -e "剩余天数: ${red}${DAYS} 天（即将到期！）${none}"
    elif [[ $DAYS -le 30 ]]; then
        echo -e "剩余天数: ${yellow}${DAYS} 天（建议续期）${none}"
    else
        echo -e "剩余天数: ${green}${DAYS} 天${none}"
    fi
}

ssl_renew() {
    echo
    info "=== 手动续期证书 ==="
    echo "当前已申请的证书："
    certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:" | sed 's/^    /  /'
    echo
    read -rp "请输入要续期的域名（留空续期所有）: " DOMAIN

    do_service stop nginx >/dev/null 2>&1
    if [[ -z "$DOMAIN" ]]; then
        certbot renew --standalone
    else
        certbot certonly --standalone -d "$DOMAIN" \
            --agree-tos --register-unsafely-without-email \
            --non-interactive --force-renewal
    fi
    do_service start nginx >/dev/null 2>&1
    success "续期完成"
}

ssl_setup_cron() {
    cat > /usr/local/bin/ssl_renew.sh << 'EOF'
#!/bin/bash
systemctl stop nginx
certbot renew --standalone --quiet >> /var/log/ssl_renew.log 2>&1
systemctl start nginx
EOF
    chmod +x /usr/local/bin/ssl_renew.sh
    echo "30 3 * * * root /usr/local/bin/ssl_renew.sh" > /etc/cron.d/ssl-renew
    systemctl restart cron >/dev/null 2>&1
    success "自动续期已配置（每天 03:30 检查）"
}

ssl_menu() {
    while :; do
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "       SSL 证书管理"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " 1. 申请证书"
        echo " 2. 查询证书"
        echo " 3. 手动续期"
        echo " 4. 配置自动续期"
        echo " 0. 返回主菜单"
        echo
        read -rp "请选择 [0-4]: " c
        case $c in
            1) ssl_apply ;;
            2) ssl_query ;;
            3) ssl_renew ;;
            4) ssl_setup_cron ;;
            0) break ;;
            *) error "无效选项" ;;
        esac
    done
}

# ══════════════════════════════════════
#   NaiveProxy 管理
# ══════════════════════════════════════

naive_config_input() {
    echo
    while :; do
        read -rp "$(echo -e "请输入端口 (默认 ${cyan}443${none}): ")" naive_port
        [[ -z "$naive_port" ]] && naive_port=443
        [[ "$naive_port" == "80" ]] && error "不能使用 80 端口" && continue
        [[ "$naive_port" =~ ^[0-9]+$ ]] && [[ $naive_port -ge 1 && $naive_port -le 65535 ]] && break
        error "端口输入有误"
    done

    while :; do
        read -rp "请输入域名 (例如 n.abc.com): " domain
        [[ -n "$domain" ]] && break
        error "域名不能为空"
    done

    while :; do
        read -rp "请输入邮箱 (例如 name@abc.com): " email
        [[ -n "$email" ]] && break
        error "邮箱不能为空"
    done

    get_ip
    echo
    _yellow "请将 $domain 解析到: $ipv4"
    echo
    while :; do
        read -rp "$(echo -e "是否已解析? [${magenta}Y${none}]: ")" yn
        [[ "$yn" == [Yy] ]] && break
        error "请先完成 DNS 解析"
    done
}

install_caddy() {
    info "安装 Caddy..."
    mkdir -p /root/src && cd /root/src/
    rm -f caddy-forwardproxy-naive.tar.xz
    wget -q https://github.com/klzgrad/forwardproxy/releases/download/v2.7.5-caddy2-naive2/caddy-forwardproxy-naive.tar.xz
    tar xf caddy-forwardproxy-naive.tar.xz
    do_service stop naive >/dev/null 2>&1
    cp caddy-forwardproxy-naive/caddy /usr/bin/
    setcap cap_net_bind_service=+ep /usr/bin/caddy
    success "Caddy 安装完成"
}

install_certbot_naive() {
    info "安装依赖..."
    $cmd update -y -qq
    $cmd install -y curl wget git zip unzip qrencode libcap2-bin tar certbot dnsutils -qq
}

caddy_write_config() {
    password=$uuid
    mkdir -p /etc/caddy /etc/ssl/caddy /var/www/

    wget -qc https://raw.githubusercontent.com/imajeason/nas_tools/main/NaiveProxy/html.tar.gz -O - | tar -xz -C /var/www/

    if certbot certificates 2>/dev/null | grep -q "$domain"; then
        certbot renew
    else
        certbot certonly --standalone -d "$domain" --agree-tos --email "$email" --non-interactive
    fi

    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    timedatectl set-timezone Asia/Shanghai >/dev/null 2>&1

    cat > /etc/caddy/caddy_config.json << EOF
{
  "admin": { "disabled": true },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":$naive_port"],
          "routes": [{
            "handle": [{
              "handler": "subroute",
              "routes": [
                { "handle": [{ "auth_user_deprecated": "User", "auth_pass_deprecated": "$password", "handler": "forward_proxy", "hide_ip": true, "hide_via": true, "probe_resistance": {} }] },
                { "match": [{ "host": ["$domain"] }], "handle": [{ "handler": "file_server", "root": "/var/www/html", "index_names": ["index.html"] }], "terminal": true }
              ]
            }]
          }],
          "tls_connection_policies": [{ "match": { "sni": ["$domain"] } }],
          "automatic_https": { "disable": true }
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [{ "certificate": "/etc/letsencrypt/live/$domain/fullchain.pem", "key": "/etc/letsencrypt/live/$domain/privkey.pem" }]
      }
    }
  }
}
EOF

    cat > /etc/systemd/system/naive.service << EOF
[Unit]
Description=Caddy NaiveProxy
After=network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy_config.json
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy_config.json
TimeoutStopSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    do_service daemon-reload
    do_service enable naive
    do_service restart naive

    # 保存配置
    mkdir -p /etc/caddy
    { echo "域名domain   =$domain"
      echo "端口port     =$naive_port"
      echo "用户名user   =User"
      echo "密码password =$password"
      echo "邮箱email    =$email"
    } > /etc/caddy/.autoconfig

    # cron 续期
    cat > /etc/caddy/.renew.sh << 'EOF'
#!/bin/bash
systemctl stop naive
certbot renew
systemctl start naive
EOF
    chmod +x /etc/caddy/.renew.sh
    if ! grep -q "caddy" /var/spool/cron/root 2>/dev/null; then
        mkdir -p /var/spool/cron
        echo "0 1 * * * /etc/caddy/.renew.sh" >> /var/spool/cron/root
    fi
}

naive_show_config() {
    echo
    info "NaiveProxy 运行状态"
    do_service status naive --no-pager
    echo
    info "端口监听"
    netstat -nltp 2>/dev/null | grep caddy || ss -nltp | grep caddy
    echo
    info "配置信息"
    cat /etc/caddy/.autoconfig 2>/dev/null || error "未找到配置文件"
}

naive_install() {
    if [[ -f /usr/bin/caddy && -f /etc/caddy/caddy_config.json ]]; then
        echo
        _yellow "检测到 NaiveProxy 已安装"
        echo " 1. 重新安装"
        echo " 2. 更新 Caddy"
        echo " 0. 取消"
        read -rp "请选择: " c2
        case $c2 in
            1) do_service stop naive >/dev/null 2>&1 ;;
            2) install_caddy && do_service start naive && naive_show_config; return ;;
            *) return ;;
        esac
    fi

    naive_config_input
    install_certbot_naive
    install_caddy
    caddy_write_config
    naive_show_config
    success "NaiveProxy 安装完成！"
}

naive_edit() {
    [[ ! -f /etc/caddy/.autoconfig ]] && error "未找到配置，请先安装" && return 1

    domain=$(grep 'domain' /etc/caddy/.autoconfig | cut -d= -f2)
    naive_port=$(grep 'port' /etc/caddy/.autoconfig | cut -d= -f2)
    password=$(grep 'password' /etc/caddy/.autoconfig | cut -d= -f2)
    email=$(grep 'email' /etc/caddy/.autoconfig | cut -d= -f2)

    read -rp "$(echo -e "端口 (当前 ${cyan}${naive_port}${none}，回车不改): ")" p1
    [[ -n "$p1" ]] && naive_port=$p1
    read -rp "$(echo -e "密码 (当前 ${cyan}${password}${none}，回车不改): ")" p2
    [[ -n "$p2" ]] && password=$p2

    uuid=$password
    caddy_write_config
    success "配置已更新"
}

naive_uninstall() {
    read -rp "确认卸载 NaiveProxy? [y/N]: " yn
    [[ "$yn" != [Yy] ]] && return
    do_service disable naive >/dev/null 2>&1
    do_service stop naive >/dev/null 2>&1
    rm -f /etc/systemd/system/naive.service /usr/bin/caddy
    rm -rf /etc/caddy /root/src/caddy-forwardproxy-naive
    success "NaiveProxy 已卸载"
}

naive_cert_renew() {
    if ss -lntp | grep -qE ':80\b'; then
        error "请先关闭占用 80 端口的服务再操作"
        return 1
    fi
    certbot renew
    success "证书续签完成"
}

naive_menu() {
    while :; do
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "     NaiveProxy 管理"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " 1. 安装 / 更新"
        echo " 2. 查看配置信息"
        echo " 3. 修改配置"
        echo " 4. 重启服务"
        echo " 5. 证书续签"
        echo " 6. 卸载"
        echo " 0. 返回主菜单"
        echo
        read -rp "请选择 [0-6]: " c
        case $c in
            1) naive_install ;;
            2) naive_show_config ;;
            3) naive_edit ;;
            4) do_service restart naive && success "已重启" ;;
            5) naive_cert_renew ;;
            6) naive_uninstall ;;
            0) break ;;
            *) error "无效选项" ;;
        esac
    done
}

# ══════════════════════════════════════
#   主菜单
# ══════════════════════════════════════

while :; do
    clear
    echo
    echo -e "${green}╔══════════════════════════════════╗${none}"
    echo -e "${green}║      综合管理脚本                ║${none}"
    echo -e "${green}║      SSL证书 + NaiveProxy        ║${none}"
    echo -e "${green}╚══════════════════════════════════╝${none}"
    echo
    echo " 1. SSL 证书管理"
    echo " 2. NaiveProxy 管理"
    echo " 0. 退出"
    echo
    read -rp "请选择 [0-2]: " choose
    case $choose in
        1) ssl_menu ;;
        2) naive_menu ;;
        0) echo "退出"; exit 0 ;;
        *) error "无效选项" ;;
    esac
done
