#!/bin/bash

# ==========================================
# 专属管理工具 (sing-box v1.13+ 终极打通版) 
# 版本：4.17 修复 domain_strategy 致命报错 | 全局 IPv4 路由
# ==========================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${PLAIN}" && exit 1

SCRIPT_URL="https://raw.githubusercontent.com/qwe32912/VLESS-xhttp-Hysteria2/main/xx.sh"

# ================= 状态获取 =================

get_status() {
    VPS_IP=$(curl -s4m 2 https://api.ipify.org || echo "无法获取")
    [[ -f "/etc/sing-box/domain.txt" ]] && USED_DOMAIN=$(cat "/etc/sing-box/domain.txt") || USED_DOMAIN="未绑定域名"
    
    if [[ -f "/usr/local/bin/sing-box" ]]; then
        SB_VER=$(/usr/local/bin/sing-box version | head -n1 | awk '{print $3}')
        systemctl is-active --quiet sing-box && SB_STATUS="${GREEN}运行中 (v$SB_VER)${PLAIN}" || SB_STATUS="${RED}停止${PLAIN}"
    else
        SB_STATUS="${RED}未安装${PLAIN}"
    fi

    BBR_STATUS="${RED}未开启${PLAIN}"
    [[ $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}') == "bbr" ]] && BBR_STATUS="${GREEN}已开启${PLAIN}"

    [[ -f "/etc/sing-box/sub_info.txt" ]] && LOCAL_SUB_URL=$(cat "/etc/sing-box/sub_info.txt") || LOCAL_SUB_URL="${YELLOW}暂无订阅链接${PLAIN}"
}

# ================= 卸载逻辑 =================

uninstall() {
    echo -e "${YELLOW}正在安全卸载 sing-box 相关服务...${PLAIN}"
    systemctl stop sing-box sub-server 2>/dev/null
    systemctl disable sing-box sub-server 2>/dev/null
    rm -rf /etc/sing-box /opt/sub_server /usr/local/bin/sing-box
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sub-server.service
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
    exit 0
}

# ================= 安装逻辑 =================

install() {
    clear
    echo -e "${BLUE}--- sing-box 1.13+ 规范部署 (Reality/Hy2/Tuic) ---${PLAIN}"
    echo "1. 域名模式 (自动申请证书)"
    echo "2. 纯 IP 模式 (使用自签证书)"
    read -p "选择模式 [1-2] (默认1): " CERT_MODE; CERT_MODE=${CERT_MODE:-1}

    if [[ "$CERT_MODE" == "1" ]]; then
        read -p "请输入解析好的域名: " DOMAIN; [[ -z "$DOMAIN" ]] && exit 1
        IS_INSECURE="false"
    else
        DOMAIN=$(curl -s4m 2 https://api.ipify.org)
        IS_INSECURE="true"
    fi

    read -p "Reality 端口 (默认 443): " R_PORT; R_PORT=${R_PORT:-443}
    read -p "Hy2 端口 (默认 8443): " H_PORT; H_PORT=${H_PORT:-8443}
    read -p "TuicV5 端口 (默认 9443): " T_PORT; T_PORT=${T_PORT:-9443}
    read -p "订阅服务端口 (默认 25500): " S_PORT; S_PORT=${S_PORT:-25500}

    # 1. 环境准备
    apt update -y && apt install -y curl wget jq openssl python3 lsof ca-certificates
    lsof -i:80,443,8443,9443 | awk 'NR>1 {print $2}' | xargs kill -9 >/dev/null 2>&1
    pkill -f "http.server $S_PORT" >/dev/null 2>&1

    # 2. 安装核心
    ARCH=$(uname -m); [[ "$ARCH" == "x86_64" ]] && SB_ARCH="amd64" || SB_ARCH="arm64"
    LATEST_SB=$(curl -skL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/^v//')
    wget -qO sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_SB}/sing-box-${LATEST_SB}-linux-${SB_ARCH}.tar.gz"
    tar -zxf sb.tar.gz && mv sing-box-*/sing-box /usr/local/bin/ && chmod +x /usr/local/bin/sing-box
    rm -rf sb.tar.gz sing-box-*

    # 3. 证书处理
    CERT_DIR="/etc/sing-box/certs"; mkdir -p $CERT_DIR
    echo "$DOMAIN" > /etc/sing-box/domain.txt

    if [[ "$CERT_MODE" == "1" ]]; then
        if [[ ! -f "$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer" ]]; then
            [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl -Lk https://get.acme.sh | sh -s email=admin@$DOMAIN
            source "$HOME/.bashrc"
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force
        fi
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.cer"
    else
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.cer" -subj "/CN=$DOMAIN" >/dev/null 2>&1
    fi

    if [[ ! -s "$CERT_DIR/server.cer" || ! -s "$CERT_DIR/server.key" ]]; then
        echo -e "${RED}严重错误：证书生成失败（文件不存在或为空）！${PLAIN}"
        exit 1
    fi

    # 4. 密钥与配置生成 (应用 1.13+ 合法的全局 DNS 策略)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    RE_KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$RE_KEYS" | awk -F': ' '/PrivateKey/ {print $2}' | tr -d ' ')
    PUBLIC_KEY=$(echo "$RE_KEYS" | awk -F': ' '/PublicKey/ {print $2}' | tr -d ' ')
    SHORT_ID=$(openssl rand -hex 8)

    cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "local-dns",
        "type": "local"
      }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": $R_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.microsoft.com",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "$SHORT_ID"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "listen_port": $H_PORT,
      "users": [
        {
          "password": "$UUID"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/server.cer",
        "key_path": "$CERT_DIR/server.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "0.0.0.0",
      "listen_port": $T_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "password": "$UUID"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.cer",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      }
    ]
  }
}
EOF

    # 5. 配置校验
    echo -e "${YELLOW}正在进行 sing-box 1.13+ 规范校验...${PLAIN}"
    if ! /usr/local/bin/sing-box check -c /etc/sing-box/config.json; then
        echo -e "${RED}校验失败！请检查 JSON 语法。${PLAIN}"
        exit 1
    else
        echo -e "${GREEN}校验通过，完全符合 1.13+ 最新语法规范。${PLAIN}"
    fi

    # 6. 服务部署
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
User=root
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box

    # 7. 订阅生成与守护服务
    S_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
    mkdir -p "/opt/sub_server/$S_PATH"
    
    L_RE="vless://${UUID}@${VPS_IP}:${R_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#VLESS-Reality"
    LINK_HOST=$DOMAIN; [[ "$CERT_MODE" == "2" ]] && LINK_HOST=$VPS_IP
    L_HY="hy2://${UUID}@${LINK_HOST}:${H_PORT}/?insecure=$( [[ $CERT_MODE == "2" ]] && echo 1 || echo 0 )&sni=${LINK_HOST}#Hysteria2"
    L_TU="tuic://${UUID}:${UUID}@${LINK_HOST}:${T_PORT}?insecure=$( [[ $CERT_MODE == "2" ]] && echo 1 || echo 0 )&congestion_control=bbr&sni=${LINK_HOST}#TUIC-V5"
    printf '%s\n' "$L_RE" "$L_HY" "$L_TU" | base64 | tr -d '\n' > "/opt/sub_server/$S_PATH/index.html"
    echo "http://${VPS_IP}:${S_PORT}/${S_PATH}/" > "/etc/sing-box/sub_info.txt"

    cat > /etc/systemd/system/sub-server.service <<EOF
[Unit]
Description=Python Sub Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server $S_PORT --directory /opt/sub_server
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sub-server
    
    curl -Lk "$SCRIPT_URL" -o /usr/local/bin/xx && chmod +x /usr/local/bin/xx

    # 8. 实测看板
    clear
    echo -e "${GREEN}=============================================${PLAIN}"
    echo -e "           部署完成，系统实测状态              "
    echo -e "${GREEN}=============================================${PLAIN}"
    sleep 5
    
    ERROR_FOUND="false"
    ss -tulpn | grep -q ":$R_PORT " && echo -e "VLESS-Reality: ${GREEN}监听正常${PLAIN}" || { echo -e "VLESS-Reality: ${RED}异常${PLAIN}"; ERROR_FOUND="true"; }
    ss -tulpn | grep -q ":$H_PORT " && echo -e "Hysteria2:     ${GREEN}监听正常${PLAIN}" || { echo -e "Hysteria2:     ${RED}异常${PLAIN}"; ERROR_FOUND="true"; }
    ss -tulpn | grep -q ":$T_PORT " && echo -e "TUIC V5:       ${GREEN}监听正常${PLAIN}" || { echo -e "TUIC V5:       ${RED}异常${PLAIN}"; ERROR_FOUND="true"; }
    
    echo "---------------------------------------------"
    echo -e "订阅链接: ${BLUE}$(cat /etc/sing-box/sub_info.txt)${PLAIN}"
    echo "---------------------------------------------"
    
    if [[ "$ERROR_FOUND" == "true" ]]; then
        echo -e "${RED}⚠️ 检测到服务启动失败！为你抓取核心最新报错日志：${PLAIN}"
        echo -e "${YELLOW}================ 日志开始 =================${PLAIN}"
        journalctl -u sing-box.service --no-pager | tail -n 12
        echo -e "${YELLOW}================ 日志结束 =================${PLAIN}"
    else
        echo -e "Reality: $L_RE"
        echo -e "Hy2:     $L_HY"
        echo -e "Tuic:    $L_TU"
    fi
    echo "============================================="
    read -p "回车返回主菜单..."
}

# ================= 主菜单 =================

while true; do
    get_status
    clear
    echo "====================================================="
    echo -e "            专属管理看板 ${BLUE}(v4.17 最终版)${PLAIN}"
    echo "====================================================="
    echo -e "  本机 IP   : ${BLUE}${VPS_IP}${PLAIN}"
    echo -e "  绑定域名  : ${YELLOW}${USED_DOMAIN}${PLAIN}"
    echo -e "  sing-box  : ${SB_STATUS}"
    echo -e "  BBR 加速  : ${BBR_STATUS}"
    echo -e "  订阅链接  : ${BLUE}${LOCAL_SUB_URL}${PLAIN}"
    echo "-----------------------------------------------------"
    echo "  1. 一键安装 / 覆盖更新 (适配 1.13+ 最新内核)"
    echo "  2. 开启 BBR 系统加速"
    echo "  3. 一键完全卸载"
    echo "  0. 退出脚本"
    echo "====================================================="
    read -p "选择: " CHOICE
    case $CHOICE in
        1) install ;;
        2) 
            sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
            sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            echo -e "${GREEN}BBR 已成功开启！${PLAIN}"; sleep 2 ;;
        3) uninstall ;;
        0) exit 0 ;;
    esac
done
