#!/bin/bash

# ==========================================
# 专属管理工具 (sing-box + Juicity)
# 协议：VLESS-Reality / Hysteria2 / Juicity
# ==========================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${PLAIN}" && exit 1

# 远程脚本地址（用于 xx 命令同步）
SCRIPT_URL="https://raw.githubusercontent.com/qwe32912/VLESS-xhttp-Hysteria2/main/xx.sh"

# ================= 状态获取 =================

get_status() {
    VPS_IP=$(curl -s4m 2 https://api.ipify.org || echo "无法获取")
    
    # 检查 sing-box
    if [[ -f "/usr/local/bin/sing-box" ]]; then
        SB_VER=$(/usr/local/bin/sing-box version | head -n1 | awk '{print $3}')
        SB_STATUS="${GREEN}运行中 ($SB_VER)${PLAIN}"
    else
        SB_STATUS="${RED}未安装${PLAIN}"
    fi

    # 检查 Juicity
    [[ -f "/usr/local/bin/juicity-server" ]] && J_STATUS="${GREEN}已就绪${PLAIN}" || J_STATUS="${RED}未安装${PLAIN}"

    # BBR 状态
    [[ $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}') == "bbr" ]] && BBR_STATUS="${GREEN}已开启${PLAIN}" || BBR_STATUS="${RED}未开启${PLAIN}"

    # 订阅链接
    [[ -f "/etc/sing-box/sub_info.txt" ]] && LOCAL_SUB_URL=$(cat "/etc/sing-box/sub_info.txt") || LOCAL_SUB_URL="${YELLOW}暂无订阅链接${PLAIN}"
}

# ================= 辅助工具 =================

check_port() {
    sleep 3
    ss -tulpn | grep -q ":$1 " && echo -e "$2 ($1): ${GREEN}正常${PLAIN}" || echo -e "$2 ($1): ${RED}未监听 (异常)${PLAIN}"
}

# ================= 卸载逻辑 =================

uninstall() {
    echo -e "${YELLOW}正在清理所有服务与残留...${PLAIN}"
    systemctl stop sing-box juicity-server sub-server 2>/dev/null
    systemctl disable sing-box juicity-server sub-server 2>/dev/null
    rm -rf /etc/sing-box /usr/local/bin/sing-box /etc/juicity /usr/local/bin/juicity-server /opt/sub_server /usr/local/bin/xx
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
    exit 0
}

# ================= 安装逻辑 =================

install() {
    clear
    echo -e "${BLUE}--- sing-box 多协议部署配置 ---${PLAIN}"
    read -p "1. Reality 目标网站 (默认 www.google.com:443): " REALITY_DEST
    REALITY_DEST=${REALITY_DEST:-"www.google.com:443"}
    read -p "2. Reality 端口 (默认 443): " R_PORT
    R_PORT=${R_PORT:-443}
    read -p "3. Hy2 端口 (默认 8443): " H_PORT
    H_PORT=${H_PORT:-8443}
    read -p "4. Juicity 端口 (默认 9443): " J_PORT
    J_PORT=${J_PORT:-9443}
    read -p "5. 订阅端口 (默认 25500): " S_PORT
    S_PORT=${S_PORT:-25500}

    # 环境准备
    apt update -y && apt install -y curl wget jq openssl python3 lsof ca-certificates
    
    # 安装 sing-box
    echo -e "${BLUE}正在安装 sing-box...${PLAIN}"
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
    
    # 安装 Juicity
    echo -e "${BLUE}正在安装 Juicity...${PLAIN}"
    J_VER=$(curl -s https://api.github.com/repos/juicity/juicity/releases/latest | jq -r .tag_name)
    wget -qO juicity.tar.gz "https://github.com/juicity/juicity/releases/download/${J_VER}/juicity-server-linux-amd64.tar.gz"
    tar -zxf juicity.tar.gz && mv juicity-server /usr/local/bin/ && chmod +x /usr/local/bin/juicity-server
    rm -f juicity.tar.gz

    # 生成密钥
    UUID=$(cat /proc/sys/kernel/random/uuid)
    # Reality 密钥对
    RE_KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)
    
    # 证书处理 (Hy2 & Juicity 使用自签)
    CERT_DIR="/etc/vproxy"; mkdir -p $CERT_DIR
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.cer" -subj "/CN=$VPS_IP" >/dev/null 2>&1

    # 写入 sing-box 配置 (Reality + Hy2)
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality", "listen": "::", "listen_port": $R_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true, "server_name": "$(echo $REALITY_DEST | cut -d: -f1)",
        "reality": { "enabled": true, "handshake": { "server": "$(echo $REALITY_DEST | cut -d: -f1)", "server_port": $(echo $REALITY_DEST | cut -d: -f2) }, "private_key": "$PRIVATE_KEY", "short_id": ["$SHORT_ID"] }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $H_PORT,
      "users": [{ "password": "$UUID" }],
      "tls": { "enabled": true, "certificate_path": "$CERT_DIR/server.cer", "key_path": "$CERT_DIR/server.key" }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

    # 写入 Juicity 配置
    mkdir -p /etc/juicity
    cat > /etc/juicity/config.json <<EOF
{
  "listen": ":$J_PORT",
  "users": { "$UUID": "$UUID" },
  "certificate": "$CERT_DIR/server.cer",
  "private_key": "$CERT_DIR/server.key",
  "congestion_control": "bbr",
  "log_level": "info"
}
EOF

    # 写入 Service
    cat > /etc/systemd/system/juicity-server.service <<EOF
[Unit]
Description=Juicity Server
After=network.target
[Service]
ExecStart=/usr/local/bin/juicity-server -c /etc/juicity/config.json
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

    # 订阅与 Python Server
    S_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
    mkdir -p "/opt/sub_server/$S_PATH"
    
    # 生成链接
    L_RE="vless://${UUID}@${VPS_IP}:${R_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(echo $REALITY_DEST | cut -d: -f1)&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#Reality-singbox"
    L_HY="hy2://${UUID}@${VPS_IP}:${H_PORT}/?insecure=1&sni=www.bing.com#Hysteria2-singbox"
    L_JU="juicity://${UUID}:${UUID}@${VPS_IP}:${J_PORT}?sni=www.google.com&insecure=1#Juicity"
    
    printf '%s\n' "$L_RE" "$L_HY" "$L_JU" | base64 | tr -d '\n' > "/opt/sub_server/$S_PATH/index.html"
    echo "http://${VPS_IP}:${S_PORT}/${S_PATH}/" > "/etc/sing-box/sub_info.txt"

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

    systemctl daemon-reload
    systemctl enable --now sing-box juicity-server sub-server
    systemctl restart sing-box juicity-server sub-server

    # 固化 xx 命令
    curl -Lk "$SCRIPT_URL" -o /usr/local/bin/xx && chmod +x /usr/local/bin/xx

    clear
    echo -e "${GREEN}=============================================${PLAIN}"
    check_port $R_PORT "VLESS-Reality"
    check_port $H_PORT "Hysteria2"
    check_port $J_PORT "Juicity"
    echo -e "---------------------------------------------"
    echo -e "订阅链接: ${BLUE}$(cat /etc/sing-box/sub_info.txt)${PLAIN}"
    echo -e "Reality: ${YELLOW}$L_RE${PLAIN}"
    echo -e "Hy2:     ${YELLOW}$L_HY${PLAIN}"
    echo -e "Juicity: ${YELLOW}$L_JU${PLAIN}"
    echo -e "${GREEN}=============================================${PLAIN}"
    read -p "回车返回主菜单..."
}

# ================= 循环主菜单 =================

while true; do
    get_status
    clear
    echo "====================================================="
    echo -e "           sing-box 综合管理看板 ${BLUE}(v3.0)${PLAIN}"
    echo "====================================================="
    echo -e "  本机 IP   : ${BLUE}${VPS_IP}${PLAIN}"
    echo -e "  sing-box  : ${SB_STATUS}"
    echo -e "  Juicity   : ${J_STATUS}"
    echo -e "  BBR 加速  : ${BBR_STATUS}"
    echo -e "  订阅链接  : ${BLUE}${LOCAL_SUB_URL}${PLAIN}"
    echo "-----------------------------------------------------"
    echo "  1. 一键安装 / 覆盖更新 (Reality/Hy2/Juicity)"
    echo "  2. 开启 BBR 加速"
    echo "  3. 一键完全卸载"
    echo "  0. 退出"
    echo "====================================================="
    read -p "选择: " CHOICE
    case $CHOICE in
        1) install ;;
        2) 
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1 && sleep 2 ;;
        3) uninstall ;;
        *) exit 0 ;;
    esac
done
