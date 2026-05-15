#!/bin/bash

# ==========================================
# 专属管理工具 (Juicity 协议 v0.5.0+ 专用版) 
# 版本：5.2 | 补全 ALPN 参数 | 智能证书复用
# ==========================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须以 root 权限运行!${PLAIN}" && exit 1

# ================= 状态获取 =================

get_status() {
    VPS_IP=$(curl -s4m 2 https://api.ipify.org || echo "无法获取")
    [[ -f "/etc/juicity/domain.txt" ]] && USED_DOMAIN=$(cat "/etc/juicity/domain.txt") || USED_DOMAIN="未绑定域名"
    
    if [[ -f "/usr/local/bin/juicity-server" ]]; then
        JC_VER=$(/usr/local/bin/juicity-server --version | awk '{print $3}')
        systemctl is-active --quiet juicity && JC_STATUS="${GREEN}运行中 (v$JC_VER)${PLAIN}" || JC_STATUS="${RED}停止${PLAIN}"
    else
        JC_STATUS="${RED}未安装${PLAIN}"
    fi

    BBR_STATUS="${RED}未开启${PLAIN}"
    [[ $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}') == "bbr" ]] && BBR_STATUS="${GREEN}已开启${PLAIN}"
}

# ================= 卸载逻辑 =================

uninstall() {
    echo -e "${YELLOW}正在安全卸载 Juicity 相关服务...${PLAIN}"
    systemctl stop juicity 2>/dev/null
    systemctl disable juicity 2>/dev/null
    rm -rf /etc/juicity /usr/local/bin/juicity-server
    rm -f /etc/systemd/system/juicity.service
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
    exit 0
}

# ================= 安装逻辑 =================

install() {
    clear
    echo -e "${BLUE}--- Juicity 协议规范部署 ---${PLAIN}"
    
    # 1. 交互输入
    read -p "请输入解析好的域名: " DOMAIN; [[ -z "$DOMAIN" ]] && exit 1
    read -p "Juicity 监听端口 (默认 443): " J_PORT; J_PORT=${J_PORT:-443}
    
    # 2. 环境准备
    apt update -y && apt install -y curl wget jq lsof ca-certificates unzip
    
    # 3. 安装 Juicity 核心
    echo -e "${YELLOW}正在拉取最新二进制文件...${PLAIN}"
    LATEST_JC=$(curl -s https://api.github.com/repos/juicity/juicity/releases/latest | jq -r .tag_name)
    wget -L -O juicity.zip "https://github.com/juicity/juicity/releases/download/${LATEST_JC}/juicity-linux-x86_64.zip"
    unzip -o juicity.zip
    mv juicity-server /usr/local/bin/ && chmod +x /usr/local/bin/juicity-server
    rm -f juicity.zip juicity-client example* README.md LICENSE

    # 4. 智能证书处理
    CERT_DIR="/etc/juicity/certs"; mkdir -p $CERT_DIR
    echo "$DOMAIN" > /etc/juicity/domain.txt

    NEED_ISSUE="true"
    if [[ -s "$CERT_DIR/server.cer" && -s "$CERT_DIR/server.key" ]]; then
        echo -e "${GREEN}检测到 /etc/juicity/certs 已有证书，跳过申请。${PLAIN}"
        NEED_ISSUE="false"
    elif [[ -f "$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer" ]]; then
        echo -e "${GREEN}检测到 acme.sh 已有备份证书，正在同步...${PLAIN}"
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.cer"
        NEED_ISSUE="false"
    fi

    if [[ "$NEED_ISSUE" == "true" ]]; then
        echo -e "${YELLOW}未发现有效证书，准备申请...${PLAIN}"
        lsof -i:80 | awk 'NR>1 {print $2}' | xargs kill -9 >/dev/null 2>&1
        if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
            curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        fi
        source "$HOME/.bashrc"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.cer"
    fi

    if [[ ! -s "$CERT_DIR/server.cer" ]]; then
        echo -e "${RED}错误：证书获取失败！${PLAIN}"
        exit 1
    fi

    # 5. 生成配置文件 (服务端默认支持 h3)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)

    cat > /etc/juicity/config.json <<EOF
{
  "listen": ":$J_PORT",
  "certificate": "$CERT_DIR/server.cer",
  "private_key": "$CERT_DIR/server.key",
  "users": {
    "$UUID": "$PASSWORD"
  },
  "congestion_control": "bbr",
  "log_level": "info"
}
EOF

    # 6. 服务部署
    cat > /etc/systemd/system/juicity.service <<EOF
[Unit]
Description=Juicity Service
After=network.target

[Service]
ExecStart=/usr/local/bin/juicity-server run -c /etc/juicity/config.json
Restart=always
User=root
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

    # 7. 内核优化
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
    echo "net.core.rmem_max=67108864" >> /etc/sysctl.conf
    echo "net.core.wmem_max=67108864" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    systemctl daemon-reload
    systemctl enable --now juicity

    # 8. 输出结果 (增加 alpn=h3)
    clear
    echo -e "${GREEN}=============================================${PLAIN}"
    echo -e "           Juicity 部署完成 (v5.2)           "
    echo -e "${GREEN}=============================================${PLAIN}"
    echo -e "域名: $DOMAIN"
    echo -e "端口: $J_PORT (UDP)"
    echo -e "UUID: $UUID"
    echo -e "密码: $PASSWORD"
    echo -e "---------------------------------------------"
    echo -e "${BLUE}分享链接 (已补全 ALPN 参数):${PLAIN}"
    echo -e "${YELLOW}juicity://${UUID}:${PASSWORD}@${DOMAIN}:${J_PORT}?sni=${DOMAIN}&congestion_control=bbr&alpn=h3&allow_insecure=0#Juicity-Node${PLAIN}"
    echo -e "${GREEN}=============================================${PLAIN}"
    read -p "回车返回主菜单..."
}

# ================= 主菜单 =================

while true; do
    get_status
    clear
    echo "====================================================="
    echo -e "           Juicity 管理看板 ${BLUE}(v5.2 规范版)${PLAIN}"
    echo "====================================================="
    echo -e "  本机 IP   : ${BLUE}${VPS_IP}${PLAIN}"
    echo -e "  绑定域名  : ${YELLOW}${USED_DOMAIN}${PLAIN}"
    echo -e "  服务状态  : ${JC_STATUS}"
    echo -e "  BBR 加速  : ${BBR_STATUS}"
    echo "-----------------------------------------------------"
    echo "  1. 安装 / 覆盖更新 Juicity"
    echo "  2. 开启 BBR 加速"
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
            echo -e "${GREEN}BBR 已开启！${PLAIN}"; sleep 2 ;;
        3) uninstall ;;
        0) exit 0 ;;
    esac
done
