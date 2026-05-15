#!/bin/bash

# ==========================================
# 专属管理工具 (VLESS-xhttp + Hysteria2)
# 逻辑严谨版：核心文件校验 + 详细节点输出
# ==========================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${PLAIN}" && exit 1

# ================= 状态与数据提取 =================

get_status() {
    # 1. 获取 IP
    VPS_IP=$(curl -s4m 2 https://api.ipify.org || echo "无法获取")
    
    # 2. 节点核心安装判定 (必须二进制和配置都在才算已安装)
    if [[ -f "/usr/local/bin/xray" && -f "/usr/local/bin/hysteria" ]]; then
        # 进一步检查服务是否在运行
        X_RUN=$(systemctl is-active xray)
        H_RUN=$(systemctl is-active hysteria-server)
        if [[ "$X_RUN" == "active" && "$H_RUN" == "active" ]]; then
            NODE_STATUS="${GREEN}运行中 (已安装)${PLAIN}"
        else
            NODE_STATUS="${YELLOW}已安装 (服务未启动)${PLAIN}"
        fi
    else
        NODE_STATUS="${RED}未安装 / 核心缺失${PLAIN}"
    fi

    # 3. BBR 状态
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        BBR_STATUS="${GREEN}已开启${PLAIN}"
    else
        BBR_STATUS="${RED}未开启${PLAIN}"
    fi

    # 4. 提取本地存储的订阅链接
    SUB_INFO_FILE="/etc/vproxy/sub_info.txt"
    if [ -f "$SUB_INFO_FILE" ]; then
        LOCAL_SUB_URL=$(cat "$SUB_INFO_FILE")
    else
        LOCAL_SUB_URL="${YELLOW}暂无订阅信息${PLAIN}"
    fi
}

# ================= 连通性工具 =================

check_port() {
    ss -tulpn | grep -q ":$1 " && return 0 || return 1
}

# ================= 开启 BBR =================

enable_bbr() {
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}BBR 加速开启成功！${PLAIN}"
    sleep 2
}

# ================= 卸载逻辑 =================

uninstall() {
    echo -e "${YELLOW}正在清理节点服务与核心文件...${PLAIN}"
    systemctl stop xray hysteria-server sub-server 2>/dev/null
    systemctl disable xray hysteria-server sub-server 2>/dev/null
    
    # 仅移除当前域名的证书任务，不破坏 acme 环境
    if [ -f "/etc/vproxy/domain.txt" ]; then
        DOMAIN=$(cat /etc/vproxy/domain.txt)
        ~/.acme.sh/acme.sh --remove -d "$DOMAIN" >/dev/null 2>&1
    fi

    rm -rf /etc/vproxy /usr/local/etc/xray /etc/hysteria /opt/sub_server
    rm -f /usr/local/bin/xray /usr/local/bin/hysteria
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria-server.service /etc/systemd/system/sub-server.service
    systemctl daemon-reload
    
    echo -e "${GREEN}卸载完成。若不再需要管理脚本，可手动执行: rm -f /usr/local/bin/xx${PLAIN}"
    exit 0
}

# ================= 安装逻辑 =================

install() {
    clear
    echo -e "${BLUE}--- 部署配置 ---${PLAIN}"
    read -p "请输入解析好的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1
    read -p "Xray 端口 (默认 443): " X_PORT
    X_PORT=${X_PORT:-443}
    read -p "Hy2 端口 (默认 8443): " H_PORT
    H_PORT=${H_PORT:-8443}
    read -p "订阅端口 (默认 25500): " S_PORT
    S_PORT=${S_PORT:-25500}

    # 依赖安装
    apt update -y && apt install -y curl wget socat jq openssl python3 lsof ca-certificates
    update-ca-certificates --fresh >/dev/null 2>&1

    UUID=$(cat /proc/sys/kernel/random/uuid)
    X_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 8)
    S_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
    CERT_DIR="/etc/vproxy"
    mkdir -p $CERT_DIR

    # 核心下载
    bash -c "$(curl -Lk https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    bash <(curl -fsSLk https://get.hy2.sh/)
    
    X_BIN=$(which xray); H_BIN=$(which hysteria)

    # 证书申请
    echo "$DOMAIN" > $CERT_DIR/domain.txt
    lsof -i:80 | awk 'NR==2 {print $2}' | xargs kill -9 2>/dev/null
    [ ! -f "$HOME/.acme.sh/acme.sh" ] && curl -Lk https://get.acme.sh | sh -s email=admin@$DOMAIN
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force --insecure
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.cer"
    chmod 644 $CERT_DIR/*.key $CERT_DIR/*.cer

    # 配置写入 (Xray)
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $X_PORT, "protocol": "vless",
    "settings": { "clients": [{"id": "$UUID"}], "decryption": "none" },
    "streamSettings": {
      "network": "xhttp", "security": "tls",
      "tlsSettings": { "certificates": [{"certificateFile": "$CERT_DIR/server.cer", "keyFile": "$CERT_DIR/server.key"}] },
      "xhttpSettings": { "mode": "auto", "host": "$DOMAIN", "path": "/$X_PATH" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

    # 配置写入 (Hy2)
    mkdir -p /etc/hysteria
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

    # 写入 Service
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
Description=Hysteria
After=network.target
[Service]
User=root
ExecStart=$H_BIN server -c /etc/hysteria/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # 订阅生成
    mkdir -p "/opt/sub_server/$S_PATH"
    V_LINK="vless://${UUID}@${DOMAIN}:${X_PORT}?encryption=none&security=tls&type=xhttp&host=${DOMAIN}&sni=${DOMAIN}&path=%2F${X_PATH}#VLESS-xhttp"
    H_LINK="hy2://${UUID}@${DOMAIN}:${H_PORT}/?sni=${DOMAIN}#Hysteria2"
    printf '%s\n' "$V_LINK" "$H_LINK" | base64 | tr -d '\n' > "/opt/sub_server/$S_PATH/index.html"

    # 保存订阅地址到文件供主页调用
    echo "http://${DOMAIN}:${S_PORT}/${S_PATH}/" > "/etc/vproxy/sub_info.txt"

    cat > /etc/systemd/system/sub-server.service <<EOF
[Unit]
Description=SubServer
[Service]
ExecStart=/usr/bin/python3 -m http.server $S_PORT
WorkingDirectory=/opt/sub_server
User=root
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray hysteria-server sub-server
    systemctl restart xray hysteria-server sub-server

    # 快捷命令固化
    CUR_SCRIPT=$(readlink -f "$0")
    cp "$CUR_SCRIPT" /usr/local/bin/xx && chmod +x /usr/local/bin/xx

    # 结果展示
    clear
    echo -e "${GREEN}=============================================${PLAIN}"
    echo -e "${GREEN}           节点安装成功，实测状态如下          ${PLAIN}"
    echo -e "${GREEN}=============================================${PLAIN}"
    check_port $X_PORT && echo -e "VLESS-xhttp: ${GREEN}监听中 (OK)${PLAIN}" || echo -e "VLESS-xhttp: ${RED}异常${PLAIN}"
    check_port $H_PORT && echo -e "Hysteria2:   ${GREEN}监听中 (OK)${PLAIN}" || echo -e "Hysteria2:   ${RED}异常${PLAIN}"
    echo -e "---------------------------------------------"
    echo -e "【订阅链接】"
    echo -e "${BLUE}http://${DOMAIN}:${S_PORT}/${S_PATH}/${PLAIN}"
    echo -e "---------------------------------------------"
    echo -e "【VLESS 链接】"
    echo -e "${YELLOW}${V_LINK}${PLAIN}"
    echo -e "---------------------------------------------"
    echo -e "【Hysteria2 链接】"
    echo -e "${YELLOW}${H_LINK}${PLAIN}"
    echo -e "${GREEN}=============================================${PLAIN}"
    read -p "按回车返回菜单..."
}

# ================= 循环主菜单 =================

while true; do
    get_status
    clear
    echo "====================================================="
    echo -e "           专属管理看板 ${BLUE}(严谨逻辑版)${PLAIN}           "
    echo "====================================================="
    echo -e "  本机 IP   : ${BLUE}${VPS_IP}${PLAIN}"
    echo -e "  节点状态  : ${NODE_STATUS}"
    echo -e "  BBR 加速  : ${BBR_STATUS}"
    echo -e "  订阅链接  : ${BLUE}${LOCAL_SUB_URL}${PLAIN}"
    echo "-----------------------------------------------------"
    echo "  1. 一键安装 / 覆盖更新 (自定义端口)"
    echo "  2. 开启 BBR 系统加速"
    echo "  3. 一键完全卸载 (清理核心文件)"
    echo "  0. 退出脚本"
    echo "====================================================="
    read -p "请选择: " CHOICE

    case $CHOICE in
        1) install ;;
        2) enable_bbr ;;
        3) uninstall ;;
        0) exit 0 ;;
        *) echo "无效输入" ; sleep 1 ;;
    esac
done
