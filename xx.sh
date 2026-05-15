#!/bin/bash

# ==========================================
# 专属管理工具 (VLESS-xhttp + Hysteria2)
# 版本：3.0 终极版 (修复快捷键 + 增加自签模式)
# ==========================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${PLAIN}" && exit 1

# GitHub 脚本原始地址 (用于固化 xx 命令)
SCRIPT_URL="https://raw.githubusercontent.com/qwe32912/VLESS-xhttp-Hysteria2/main/xx.sh"

# ================= 状态获取 =================

get_status() {
    VPS_IP=$(curl -s4m 2 https://api.ipify.org || echo "无法获取")
    
    # 核心安装判定
    if [[ -f "/usr/local/bin/xray" && -f "/usr/local/bin/hysteria" ]]; then
        if ss -tulpn | grep -qE ":(443|8443|25500) " ; then
            NODE_STATUS="${GREEN}运行中 (已通过端口实测)${PLAIN}"
        else
            NODE_STATUS="${YELLOW}已安装 (服务异常或未启动)${PLAIN}"
        fi
    else
        NODE_STATUS="${RED}未安装${PLAIN}"
    fi

    # BBR 状态
    BBR_STATUS="${RED}未开启${PLAIN}"
    [[ $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}') == "bbr" ]] && BBR_STATUS="${GREEN}已开启${PLAIN}"

    # 订阅信息
    [[ -f "/etc/vproxy/sub_info.txt" ]] && LOCAL_SUB_URL=$(cat "/etc/vproxy/sub_info.txt") || LOCAL_SUB_URL="${YELLOW}暂无订阅链接${PLAIN}"
}

# ================= 证书生成 (自签模式) =================

gen_self_signed_cert() {
    local cert_dir=$1
    local ip=$2
    echo -e "${BLUE}正在生成 IP 自签证书...${PLAIN}"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$cert_dir/server.key" \
        -out "$cert_dir/server.cer" \
        -subj "/C=US/ST=Mars/L=Space/O=SpaceX/CN=$ip" >/dev/null 2>&1
}

# ================= 连通性工具 =================

check_connectivity() {
    sleep 3
    ss -tulpn | grep -q ":$1 " && echo -e "$2 ($1): ${GREEN}正常 (监听中)${PLAIN}" || echo -e "$2 ($1): ${RED}异常 (未响应)${PLAIN}"
}

# ================= 卸载逻辑 =================

uninstall() {
    echo -e "${YELLOW}正在安全卸载...${PLAIN}"
    systemctl stop xray hysteria-server sub-server 2>/dev/null
    systemctl disable xray hysteria-server sub-server 2>/dev/null
    [[ -f "/etc/vproxy/domain.txt" ]] && ~/.acme.sh/acme.sh --remove -d $(cat /etc/vproxy/domain.txt) >/dev/null 2>&1
    rm -rf /etc/vproxy /usr/local/etc/xray /etc/hysteria /opt/sub_server /usr/local/bin/xray /usr/local/bin/hysteria /usr/local/bin/xx
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
    exit 0
}

# ================= 安装逻辑 =================

install() {
    clear
    echo -e "${BLUE}--- 部署配置 ---${PLAIN}"
    echo -e "1. 使用域名 (自动申请证书)"
    echo -e "2. 无域名 / 纯IP (使用自签证书)"
    read -p "请选择 [1-2] (默认1): " CERT_MODE
    CERT_MODE=${CERT_MODE:-1}

    if [[ "$CERT_MODE" == "1" ]]; then
        read -p "请输入已解析的域名: " DOMAIN
        [[ -z "$DOMAIN" ]] && exit 1
        IS_INSECURE="0"
    else
        DOMAIN=$(curl -s4m 2 https://api.ipify.org)
        echo -e "${YELLOW}检测到公网 IP: $DOMAIN，将使用自签证书模式${PLAIN}"
        IS_INSECURE="1"
    fi

    read -p "Xray 端口 (默认 443): " X_PORT; X_PORT=${X_PORT:-443}
    read -p "Hy2 端口 (默认 8443): " H_PORT; H_PORT=${H_PORT:-8443}
    read -p "订阅端口 (默认 25500): " S_PORT; S_PORT=${S_PORT:-25500}

    # 基础环境
    apt update -y && apt install -y curl wget socat jq openssl python3 lsof ca-certificates
    update-ca-certificates --fresh >/dev/null 2>&1

    UUID=$(cat /proc/sys/kernel/random/uuid)
    X_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 8)
    S_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
    CERT_DIR="/etc/vproxy"; mkdir -p $CERT_DIR

    # 证书处理
    if [[ "$CERT_MODE" == "1" ]]; then
        echo "$DOMAIN" > $CERT_DIR/domain.txt
        lsof -i:80 | awk 'NR==2 {print $2}' | xargs kill -9 2>/dev/null
        [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl -Lk https://get.acme.sh | sh -s email=admin@$DOMAIN
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force --insecure
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.cer"
    else
        gen_self_signed_cert $CERT_DIR $DOMAIN
        SNI="www.bing.com" # 自签模式混淆域名
    fi
    chmod 644 $CERT_DIR/*

    # 下载安装
    bash -c "$(curl -Lk https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    bash <(curl -fsSLk https://get.hy2.sh/)
    X_BIN=$(which xray); H_BIN=$(which hysteria)

    # 写入配置 (略...保持逻辑严谨)
    mkdir -p /usr/local/etc/xray /etc/hysteria
    # Xray Config
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $X_PORT, "protocol": "vless",
    "settings": { "clients": [{"id": "$UUID"}], "decryption": "none" },
    "streamSettings": {
      "network": "xhttp", "security": "tls",
      "tlsSettings": { "certificates": [{"certificateFile": "$CERT_DIR/server.cer", "keyFile": "$CERT_DIR/server.key"}] },
      "xhttpSettings": { "mode": "auto", "host": "${SNI:-$DOMAIN}", "path": "/$X_PATH" }
    }
  }]
}
EOF
    # Hy2 Config
    cat > /etc/hysteria/config.yaml <<EOF
listen: :$H_PORT
tls:
  cert: $CERT_DIR/server.cer
  key: $CERT_DIR/server.key
auth:
  type: password
  password: $UUID
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF

    # Service 文件与启动 (代码省略...逻辑与前述一致)
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray
After=network.target
[Service]
User=root
ExecStart=$X_BIN run -config /usr/local/etc/xray/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hy2
After=network.target
[Service]
User=root
ExecStart=$H_BIN server -c /etc/hysteria/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # 订阅与 Python Server (略)
    mkdir -p "/opt/sub_server/$S_PATH"
    V_LINK="vless://${UUID}@${DOMAIN}:${X_PORT}?encryption=none&security=tls&type=xhttp&host=${SNI:-$DOMAIN}&sni=${SNI:-$DOMAIN}&path=%2F${X_PATH}$([[ "$IS_INSECURE" == "1" ]] && echo "&allowInsecure=1")#VLESS-xhttp"
    H_LINK="hy2://${UUID}@${DOMAIN}:${H_PORT}/?sni=${SNI:-$DOMAIN}$([[ "$IS_INSECURE" == "1" ]] && echo "&insecure=1")#Hysteria2"
    printf '%s\n' "$V_LINK" "$H_LINK" | base64 | tr -d '\n' > "/opt/sub_server/$S_PATH/index.html"
    
    echo "http://${DOMAIN}:${S_PORT}/${S_PATH}/" > "/etc/vproxy/sub_info.txt"

    cat > /etc/systemd/system/sub-server.service <<EOF
[Unit]
Description=Sub
[Service]
ExecStart=/usr/bin/python3 -m http.server $S_PORT
WorkingDirectory=/opt/sub_server
User=root
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now xray hysteria-server sub-server && systemctl restart xray hysteria-server sub-server

    # 【重要】固化快捷命令：直接从云端下载脚本到本地，解决 bash <(curl) 导致的 xx 失效
    curl -Lk "$SCRIPT_URL" -o /usr/local/bin/xx && chmod +x /usr/local/bin/xx

    clear
    echo -e "${GREEN}=============================================${PLAIN}"
    check_connectivity $X_PORT "VLESS-xhttp"
    check_connectivity $H_PORT "Hysteria2"
    echo -e "---------------------------------------------"
    echo -e "订阅链接: ${BLUE}$(cat /etc/vproxy/sub_info.txt)${PLAIN}"
    echo -e "VLESS: ${YELLOW}$V_LINK${PLAIN}"
    echo -e "Hy2: ${YELLOW}$H_LINK${PLAIN}"
    echo -e "快捷管理: ${GREEN}xx${PLAIN}"
    echo -e "${GREEN}=============================================${PLAIN}"
    read -p "回车返回菜单..."
}

# ================= 菜单 =================

while true; do
    get_status
    clear
    echo "====================================================="
    echo -e "           专属管理看板 ${BLUE}(自签/自愈版)${PLAIN}"
    echo "====================================================="
    echo -e "  本机 IP   : ${BLUE}${VPS_IP}${PLAIN}"
    echo -e "  节点状态  : ${NODE_STATUS}"
    echo -e "  BBR 状态  : ${BBR_STATUS}"
    echo -e "  订阅链接  : ${BLUE}${LOCAL_SUB_URL}${PLAIN}"
    echo "-----------------------------------------------------"
    echo "  1. 一键安装 / 覆盖更新 (支持域名/IP自签)"
    echo "  2. 开启 BBR 加速"
    echo "  3. 一键完全卸载"
    echo "  0. 退出"
    echo "====================================================="
    read -p "选择: " CHOICE
    case $CHOICE in
        1) install ;;
        2) 
            sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
            sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1 && echo "BBR已开启" && sleep 2 ;;
        3) uninstall ;;
        *) exit 0 ;;
    esac
done
