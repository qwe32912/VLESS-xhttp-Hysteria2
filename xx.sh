#!/bin/bash

# ==========================================
# 专属管理工具 (sing-box + Juicity) 
# 修复版：避开官方脚本，直接下载二进制
# ==========================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${PLAIN}" && exit 1

SCRIPT_URL="https://raw.githubusercontent.com/qwe32912/VLESS-xhttp-Hysteria2/main/xx.sh"

get_status() {
    VPS_IP=$(curl -s4m 2 https://api.ipify.org || echo "无法获取")
    [[ -f "/usr/local/bin/sing-box" ]] && SB_STATUS="${GREEN}运行中${PLAIN}" || SB_STATUS="${RED}未安装${PLAIN}"
    [[ -f "/usr/local/bin/juicity-server" ]] && J_STATUS="${GREEN}已就绪${PLAIN}" || J_STATUS="${RED}未安装${PLAIN}"
    BBR_STATUS="${RED}未开启${PLAIN}"
    [[ $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}') == "bbr" ]] && BBR_STATUS="${GREEN}已开启${PLAIN}"
    [[ -f "/etc/sing-box/sub_info.txt" ]] && LOCAL_SUB_URL=$(cat "/etc/sing-box/sub_info.txt") || LOCAL_SUB_URL="${YELLOW}暂无订阅链接${PLAIN}"
}

uninstall() {
    echo -e "${YELLOW}正在清理...${PLAIN}"
    systemctl stop sing-box juicity-server sub-server 2>/dev/null
    rm -rf /etc/sing-box /usr/local/bin/sing-box /etc/juicity /usr/local/bin/juicity-server /opt/sub_server /etc/vproxy
    echo -e "${GREEN}卸载完成。${PLAIN}"
    exit 0
}

install() {
    clear
    echo -e "${BLUE}--- sing-box 部署配置 ---${PLAIN}"
    read -p "1. Reality 目标 (默认 www.google.com:443): " REALITY_DEST; REALITY_DEST=${REALITY_DEST:-"www.google.com:443"}
    read -p "2. Reality 端口 (默认 443): " R_PORT; R_PORT=${R_PORT:-443}
    read -p "3. Hy2 端口 (默认 8443): " H_PORT; H_PORT=${H_PORT:-8443}
    read -p "4. Juicity 端口 (默认 9443): " J_PORT; J_PORT=${J_PORT:-9443}
    read -p "5. 订阅端口 (默认 25500): " S_PORT; S_PORT=${S_PORT:-25500}

    apt update -y && apt install -y curl wget jq openssl python3 lsof ca-certificates

    # --- 修复版：安装 sing-box ---
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && SB_ARCH="amd64" || SB_ARCH="arm64"
    LATEST_SB=$(curl -skL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/^v//')
    [[ -z "$LATEST_SB" || "$LATEST_SB" == "null" ]] && LATEST_SB="1.9.3"
    echo -e "${BLUE}正在从 GitHub 下载 sing-box v$LATEST_SB ($SB_ARCH)...${PLAIN}"
    wget -qO sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_SB}/sing-box-${LATEST_SB}-linux-${SB_ARCH}.tar.gz"
    tar -zxf sb.tar.gz && mv sing-box-${LATEST_SB}-linux-${SB_ARCH}/sing-box /usr/local/bin/ && chmod +x /usr/local/bin/sing-box
    rm -rf sb.tar.gz sing-box-${LATEST_SB}-linux-${SB_ARCH}

    # --- 安装 Juicity ---
    echo -e "${BLUE}安装 Juicity...${PLAIN}"
    J_VER=$(curl -skL https://api.github.com/repos/juicity/juicity/releases/latest | jq -r .tag_name)
    wget -qO j.tar.gz "https://github.com/juicity/juicity/releases/download/${J_VER}/juicity-server-linux-amd64.tar.gz"
    tar -zxf j.tar.gz && mv juicity-server /usr/local/bin/ && chmod +x /usr/local/bin/juicity-server
    rm -f j.tar.gz

    # --- 密钥生成 ---
    UUID=$(cat /proc/sys/kernel/random/uuid)
    RE_KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)
    CERT_DIR="/etc/vproxy"; mkdir -p $CERT_DIR
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.cer" -subj "/CN=$VPS_IP" >/dev/null 2>&1

    # --- 配置文件生成 ---
    mkdir -p /etc/sing-box /etc/juicity
    cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-in", "listen": "::", "listen_port": $R_PORT,
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

    cat > /etc/juicity/config.json <<EOF
{
  "listen": ":$J_PORT", "users": { "$UUID": "$UUID" },
  "certificate": "$CERT_DIR/server.cer", "private_key": "$CERT_DIR/server.key",
  "congestion_control": "bbr", "log_level": "info"
}
EOF

    # --- 服务启动 ---
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/juicity-server.service <<EOF
[Unit]
Description=Juicity
After=network.target
[Service]
ExecStart=/usr/local/bin/juicity-server -c /etc/juicity/config.json
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

    S_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
    mkdir -p "/opt/sub_server/$S_PATH"
    L_RE="vless://${UUID}@${VPS_IP}:${R_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(echo $REALITY_DEST | cut -d: -f1)&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#Reality"
    L_HY="hy2://${UUID}@${VPS_IP}:${H_PORT}/?insecure=1&sni=www.bing.com#Hysteria2"
    L_JU="juicity://${UUID}:${UUID}@${VPS_IP}:${J_PORT}?sni=www.google.com&insecure=1#Juicity"
    printf '%s\n' "$L_RE" "$L_HY" "$L_JU" | base64 | tr -d '\n' > "/opt/sub_server/$S_PATH/index.html"
    echo "http://${VPS_IP}:${S_PORT}/${S_PATH}/" > "/etc/sing-box/sub_info.txt"

    cat > /etc/systemd/system/sub-server.service <<EOF
[Unit]
Description=Sub
[Service]
ExecStart=/usr/bin/python3 -m http.server $S_PORT
WorkingDirectory=/opt/sub_server
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box juicity-server sub-server
    systemctl restart sing-box juicity-server sub-server
    curl -Lk "$SCRIPT_URL" -o /usr/local/bin/xx && chmod +x /usr/local/bin/xx
    
    echo -e "${GREEN}部署完成！订阅链接: $(cat /etc/sing-box/sub_info.txt)${PLAIN}"
}

while true; do
    get_status
    clear
    echo "====================================================="
    echo -e "           sing-box 综合管理看板 ${BLUE}(修复版)${PLAIN}"
    echo "====================================================="
    echo -e "  IP: ${VPS_IP} | sing-box: ${SB_STATUS} | BBR: ${BBR_STATUS}"
    echo -e "  订阅: ${BLUE}${LOCAL_SUB_URL}${PLAIN}"
    echo "-----------------------------------------------------"
    echo "  1. 一键安装 / 覆盖更新"
    echo "  2. 开启 BBR"
    echo "  3. 卸载"
    echo "  0. 退出"
    read -p "选择: " CHOICE
    case $CHOICE in
        1) install ;;
        2) echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf; echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf; sysctl -p >/dev/null 2>&1 ;;
        3) uninstall ;;
        0) exit 0 ;;
    esac
done
