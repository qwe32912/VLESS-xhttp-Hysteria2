#!/bin/bash

# ==========================================
# 专属科学上网工具 (VLESS-xhttp + Hysteria2)
# 功能：状态看板 / 快捷命令 / 安全卸载 / BBR管理
# ==========================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${PLAIN}" && exit 1

# ================= 状态获取 =================

get_status() {
    # 1. 获取 IP
    VPS_IP=$(curl -s4m 2 https://api.ipify.org || echo "无法获取")
    
    # 2. 检查 Xray 状态
    if [ -f "/usr/local/bin/xray" ]; then
        XRAY_VER=$(/usr/local/bin/xray version | head -n1 | awk '{print $2}')
        XRAY_STATUS="${GREEN}已安装 ($XRAY_VER)${PLAIN}"
    else
        XRAY_STATUS="${RED}未安装${PLAIN}"
    fi

    # 3. 检查 BBR 状态
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        BBR_STATUS="${GREEN}已开启${PLAIN}"
    else
        BBR_STATUS="${RED}未开启${PLAIN}"
    fi

    # 4. 检查脚本快捷命令
    if [ -f "/usr/local/bin/xx" ]; then
        SCRIPT_STATUS="${GREEN}已配置快捷命令 (xx)${PLAIN}"
    else
        SCRIPT_STATUS="${RED}未配置快捷命令${PLAIN}"
    fi
}

# ================= BBR 开启功能 =================

enable_bbr() {
    echo -e "${BLUE}正在开启 BBR 加速...${PLAIN}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}BBR 已经处于开启状态。${PLAIN}"
    else
        # 写入配置，先删除旧的冲突行
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "${GREEN}BBR 加速已成功开启！${PLAIN}"
    fi
    read -p "按回车键返回菜单..."
}

# ================= 安全卸载 =================

uninstall() {
    echo -e "${YELLOW}正在安全卸载服务...${PLAIN}"
    systemctl stop xray hysteria-server sub-server 2>/dev/null
    systemctl disable xray hysteria-server sub-server 2>/dev/null
    
    if [ -f "/etc/vproxy/domain.txt" ]; then
        DOMAIN=$(cat /etc/vproxy/domain.txt)
        echo -e "${BLUE}正在移除域名 $DOMAIN 的证书关联...${PLAIN}"
        ~/.acme.sh/acme.sh --remove -d "$DOMAIN" >/dev/null 2>&1
        rm -rf ~/.acme.sh/${DOMAIN}_ecc
    fi

    rm -rf /etc/vproxy /usr/local/etc/xray /etc/hysteria /opt/sub_server
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria-server.service /etc/systemd/system/sub-server.service
    systemctl daemon-reload
    
    echo -e "${GREEN}卸载完成！${PLAIN}"
    read -p "是否删除快捷命令 xx？(y/n): " DEL_XX
    [[ "$DEL_XX" == "y" ]] && rm -f /usr/local/bin/xx && echo -e "${GREEN}快捷命令已移除。${PLAIN}"
    exit 0
}

# ================= 安装逻辑 =================

install() {
    echo -e "${YELLOW}正在同步系统时间与证书环境...${PLAIN}"
    apt update -y && apt install --reinstall ca-certificates -y >/dev/null 2>&1
    update-ca-certificates --fresh >/dev/null 2>&1
    apt install -y curl wget socat jq openssl python3 lsof

    read -p "请输入解析好的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    XHTTP_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 8)
    SUB_PORT=$(shuf -i 20000-40000 -n 1)
    SUB_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
    CERT_DIR="/etc/vproxy"

    echo -e "${BLUE}安装核心组件...${PLAIN}"
    bash -c "$(curl -Lk https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    bash <(curl -fsSLk https://get.hy2.sh/)
    
    XRAY_BIN=$(which xray || find /usr -name xray -type f | head -n 1)
    HY2_BIN=$(which hysteria || find /usr -name hysteria -type f | head -n 1)

    mkdir -p $CERT_DIR
    echo "$DOMAIN" > $CERT_DIR/domain.txt
    lsof -i:80 | awk 'NR==2 {print $2}' | xargs kill -9 2>/dev/null
    [ ! -f "$HOME/.acme.sh/acme.sh" ] && curl -Lk https://get.acme.sh | sh -s email=admin@$DOMAIN
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force --insecure
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.cer"
    chmod 644 $CERT_DIR/server.key $CERT_DIR/server.cer

    # 写入 Xray 配置
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": 443, "protocol": "vless",
    "settings": { "clients": [{"id": "$UUID"}], "decryption": "none" },
    "streamSettings": {
      "network": "xhttp", "security": "tls",
      "tlsSettings": { "certificates": [{"certificateFile": "$CERT_DIR/server.cer", "keyFile": "$CERT_DIR/server.key"}] },
      "xhttpSettings": { "mode": "auto", "host": "$DOMAIN", "path": "/$XHTTP_PATH" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

    # 写入 Hy2 配置
    mkdir -p /etc/hysteria
    cat > /etc/hysteria/config.yaml <<EOF
listen: :8443
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

    # 写入 Service (Root 运行确保 100% 成功)
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
User=root
ExecStart=$XRAY_BIN run -config /usr/local/etc/xray/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria Server
After=network.target
[Service]
User=root
ExecStart=$HY2_BIN server -c /etc/hysteria/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # 订阅生成
    mkdir -p "/opt/sub_server/$SUB_PATH"
    VLESS_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=xhttp&host=${DOMAIN}&sni=${DOMAIN}&path=%2F${XHTTP_PATH}#VLESS-xhttp"
    HY2_LINK="hy2://${UUID}@${DOMAIN}:8443/?sni=${DOMAIN}#Hysteria2"
    printf '%s\n' "$VLESS_LINK" "$HY2_LINK" | base64 | tr -d '\n' > "/opt/sub_server/$SUB_PATH/index.html"

    cat > /etc/systemd/system/sub-server.service <<EOF
[Unit]
Description=Sub Server
[Service]
ExecStart=/usr/bin/python3 -m http.server $SUB_PORT
WorkingDirectory=/opt/sub_server
User=root
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray hysteria-server sub-server
    systemctl restart xray hysteria-server sub-server

    # 保存快捷命令
    cp "$0" /usr/local/bin/xx && chmod +x /usr/local/bin/xx
    
    echo -e "${GREEN}部署完成！快捷命令已保存。下次请输入 xx 启动管理。${PLAIN}"
    echo -e "🔗 订阅链接: ${BLUE}http://${DOMAIN}:${SUB_PORT}/${SUB_PATH}/${PLAIN}"
}

# ================= 主菜单 =================

while true; do
    get_status
    clear
    echo "====================================================="
    echo -e "           专属科学上网管理工具 ${BLUE}(BBR增强版)${PLAIN}           "
    echo "====================================================="
    echo -e "  本机 IP   : ${BLUE}${VPS_IP}${PLAIN}"
    echo -e "  脚本状态  : ${SCRIPT_STATUS}"
    echo -e "  Xray内核  : ${XRAY_STATUS}"
    echo -e "  BBR 加速  : ${BBR_STATUS}"
    echo "-----------------------------------------------------"
    echo "  1. 一键安装 / 覆盖更新"
    echo "  2. 开启 BBR 系统加速"
    echo "  3. 一键完全卸载"
    echo "  0. 退出脚本"
    echo "====================================================="
    read -p "请输入数字选择: " CHOICE

    case $CHOICE in
        1) install; break ;;
        2) enable_bbr ;;
        3) uninstall; break ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done
