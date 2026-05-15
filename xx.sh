#!/bin/bash

# ==========================================
# 专属科学上网工具 (VLESS-xhttp + Hysteria2)
# 特性: 状态看板 / 无痕运行 / 快捷命令 / 强制DNS
# ==========================================

# 确保以 root 运行
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[31m错误: 本脚本必须以 root 权限运行!\033[0m" 
   exit 1
fi

# 你的 GitHub 脚本原始地址
SCRIPT_URL="https://raw.githubusercontent.com/qwe32912/VLESS-xhttp-Hysteria2/main/xx.sh"

# ================= 状态获取 =================
get_status() {
    # 1. 获取 VPS IP
    VPS_IP=$(curl -s4m 2 https://api.ipify.org)
    [[ -z "$VPS_IP" ]] && VPS_IP="无法获取"

    # 2. 检查脚本是否安装
    if [ -f "/usr/local/bin/xx" ]; then
        SCRIPT_STATUS="\033[32m已安装\033[0m (快捷命令: xx)"
    else
        SCRIPT_STATUS="\033[31m未安装\033[0m (内存无痕运行中)"
    fi

    # 3. 检查 Xray 状态、版本与更新
    if [ -f "/usr/local/bin/xray" ]; then
        # 获取本地版本
        LOCAL_XRAY_VER=$(/usr/local/bin/xray version | head -n1 | awk '{print $2}')
        # 去除可能存在的 'v' 前缀
        LOCAL_CLEAN=${LOCAL_XRAY_VER#v}
        
        # 获取 GitHub 最新版本号
        LATEST_XRAY_VER=$(curl -s --max-time 2 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
        
        if [[ -z "$LATEST_XRAY_VER" ]]; then
            XRAY_STATUS="\033[32m已安装\033[0m (v${LOCAL_CLEAN}) - \033[33m无法检测更新\033[0m"
        else
            LATEST_CLEAN=${LATEST_XRAY_VER#v}
            if [[ "$LOCAL_CLEAN" != "$LATEST_CLEAN" ]]; then
                XRAY_STATUS="\033[32m已安装\033[0m (v${LOCAL_CLEAN}) - \033[33m发现新版: v${LATEST_CLEAN}\033[0m"
            else
                XRAY_STATUS="\033[32m已安装\033[0m (v${LOCAL_CLEAN}) - \033[36m已是最新版\033[0m"
            fi
        fi
    else
        XRAY_STATUS="\033[31m未安装\033[0m"
    fi
}

# ================= 卸载功能 =================
uninstall() {
    clear
    echo "====================================================="
    echo "                 正在执行一键卸载...                 "
    echo "====================================================="
    
    systemctl stop xray hysteria-server sub-server 2>/dev/null
    systemctl disable xray hysteria-server sub-server 2>/dev/null
    
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/bin/xray
    rm -rf /etc/hysteria
    rm -f /usr/local/bin/hysteria
    rm -rf /opt/sub_server
    
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray@.service
    rm -f /etc/systemd/system/hysteria-server.service
    rm -f /etc/systemd/system/hysteria-server@.service
    rm -f /etc/systemd/system/sub-server.service
    
    rm -rf /etc/ssl/private/*
    rm -rf /etc/ssl/certs/*
    
    systemctl daemon-reload
    
    echo -e "\033[32m[+] 节点服务及配置文件已全部清理！\033[0m"
    echo ""
    read -p "是否要连同快捷管理菜单 (xx) 一起删除？(y/n): " DEL_MENU
    if [[ "$DEL_MENU" == "y" || "$DEL_MENU" == "Y" ]]; then
        rm -f /usr/local/bin/xx
        echo -e "\033[32m[+] 快捷命令 xx 已删除。\033[0m"
    fi
    exit 0
}

# ================= 安装功能 =================
install() {
    clear
    echo "====================================================="
    echo "   专属配置工具: VLESS(xhttp) + Hysteria2 + 订阅生成"
    echo "====================================================="
    echo ""
    echo "请选择证书配置模式："
    echo "  1) 使用已解析的域名 (推荐，自动申请 Let's Encrypt 证书)"
    echo "  2) 无域名，使用纯 IP + 自签证书 (需客户端开启允许不安全连接)"
    read -p "请输入选项 [1/2] (默认 1): " CERT_MODE
    CERT_MODE=${CERT_MODE:-1}

    echo ""
    read -p "请输入 Xray 监听端口 (默认 443): " XRAY_PORT
    XRAY_PORT=${XRAY_PORT:-443}

    read -p "请输入 Hysteria2 监听端口 (默认 8443): " HY2_PORT
    HY2_PORT=${HY2_PORT:-8443}

    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$UUID
    XHTTP_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 8)
    SUB_PORT=$(shuf -i 10000-60000 -n 1)
    SUB_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 10)

    echo ""
    echo "[*] 正在检查并开启 BBR 加速..."
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "\033[32m[+] BBR 加速已成功开启。\033[0m"
    else
        sysctl -p
        echo -e "\033[32m[+] BBR 已经处于配置状态。\033[0m"
    fi

    echo "[*] 正在安装基础环境依赖..."
    apt update && apt install -y curl wget socat jq openssl python3

    mkdir -p /etc/ssl/private /etc/ssl/certs

    if [ "$CERT_MODE" == "1" ]; then
        read -p "请输入已解析的域名 (如 proxy.example.com): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo "域名不能为空，退出。"
            exit 1
        fi
        
        echo "[*] 正在通过 acme.sh 申请证书 (需 80 端口放行)..."
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        source ~/.bashrc

        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone

        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file       /etc/ssl/private/$DOMAIN.key  \
        --fullchain-file /etc/ssl/certs/$DOMAIN.cer \
        --reloadcmd     "systemctl restart xray && systemctl restart hysteria-server"

        CERT_FILE="/etc/ssl/certs/$DOMAIN.cer"
        KEY_FILE="/etc/ssl/private/$DOMAIN.key"
        HOST_ADDRESS=$DOMAIN
        SNI=$DOMAIN
    else
        DEFAULT_IP=$(curl -s4 https://api.ipify.org)
        read -p "请输入本机公网 IP (默认: $DEFAULT_IP): " SERVER_IP
        SERVER_IP=${SERVER_IP:-$DEFAULT_IP}
        
        echo "[*] 正在生成 10 年期自签证书..."
        SNI="www.bing.com"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/ssl/private/self_signed.key \
            -out /etc/ssl/certs/self_signed.cer \
            -subj "/C=US/ST=CA/L=LosAngeles/O=Microsoft/CN=$SNI" >/dev/null 2>&1
            
        CERT_FILE="/etc/ssl/certs/self_signed.cer"
        KEY_FILE="/etc/ssl/private/self_signed.key"
        HOST_ADDRESS=$SERVER_IP
    fi

    echo "[*] 正在部署/更新 Xray-core (开启强制 DNS 防泄露)..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://8.8.8.8/dns-query",
      "localhost"
    ]
  },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{"certificateFile": "$CERT_FILE", "keyFile": "$KEY_FILE"}]
        },
        "xhttpSettings": {
          "mode": "auto",
          "host": "$SNI",
          "path": "/$XHTTP_PATH"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "UseIP",
    "rules": [
      { "type": "field", "outboundTag": "block", "ip": ["geoip:private"] }
    ]
  },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

    echo "[*] 正在部署/更新 Hysteria2 (开启强制 DoH 解析)..."
    bash <(curl -fsSL https://get.hy2.sh/)

cat > /etc/hysteria/config.yaml <<EOF
listen: :$HY2_PORT
tls:
  cert: $CERT_FILE
  key: $KEY_FILE
auth:
  type: password
  password: $HY2_PASS
resolver:
  type: https
  https:
    url: https://cloudflare-dns.com/dns-query
masquerade:
  type: proxy
  proxy:
    url: https://$SNI
    rewriteHost: true
EOF

    echo "[*] 正在生成节点链接与轻量级订阅服务..."
    if [ "$CERT_MODE" == "1" ]; then
        VLESS_LINK="vless://${UUID}@${HOST_ADDRESS}:${XRAY_PORT}?encryption=none&security=tls&type=xhttp&host=${SNI}&sni=${SNI}&path=%2F${XHTTP_PATH}#VLESS-xhttp"
        HY2_LINK="hy2://${HY2_PASS}@${HOST_ADDRESS}:${HY2_PORT}/?sni=${SNI}&insecure=0#Hysteria2"
    else
        VLESS_LINK="vless://${UUID}@${HOST_ADDRESS}:${XRAY_PORT}?encryption=none&security=tls&type=xhttp&host=${SNI}&sni=${SNI}&path=%2F${XHTTP_PATH}&allowInsecure=1#VLESS-xhttp(IP自签)"
        HY2_LINK="hy2://${HY2_PASS}@${HOST_ADDRESS}:${HY2_PORT}/?sni=${SNI}&insecure=1#Hysteria2(IP自签)"
    fi

    mkdir -p /opt/sub_server/$SUB_PATH
    echo -e "${VLESS_LINK}\n${HY2_LINK}" | base64 -w 0 > /opt/sub_server/$SUB_PATH/index.html

cat > /etc/systemd/system/sub-server.service <<EOF
[Unit]
Description=Simple Subscription Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/sub_server
ExecStart=/usr/bin/python3 -m http.server $SUB_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray hysteria-server sub-server
    systemctl restart xray hysteria-server sub-server

    # === 核心：将脚本写入本地并设置快捷命令 ===
    echo "[*] 正在将管理菜单写入系统快捷命令..."
    wget -qO /usr/local/bin/xx "$SCRIPT_URL"
    chmod +x /usr/local/bin/xx

    clear
    echo "====================================================="
    echo -e "\033[32m                  部署全部完成！                     \033[0m"
    echo "====================================================="
    if [ "$CERT_MODE" == "1" ]; then
        echo "证书模式: Let's Encrypt 域名证书"
    else
        echo "证书模式: 纯 IP 自签证书 (⚠️客户端必须开启“允许不安全连接”)"
    fi
    echo "防泄露保护: Xray (UseIP + 1.1.1.1) | Hy2 (Cloudflare DoH)"
    echo "====================================================="
    echo "【你的私密订阅链接】(直接复制到客户端更新订阅)"
    echo -e "🔗 \033[36mhttp://${HOST_ADDRESS}:${SUB_PORT}/${SUB_PATH}/\033[0m"
    echo "====================================================="
    echo -e "\033[33m💡 提示: 快捷命令已经注册成功！\033[0m"
    echo "以后随时在终端输入 xx 即可再次唤出本菜单"
    echo "====================================================="
}

# ================= 主菜单渲染 =================
# 在显示菜单前，先抓取系统状态
get_status

clear
echo "====================================================="
echo "        专属科学上网搭建工具 (多协议极简版)        "
echo "====================================================="
echo -e "  本机 IP  : \033[36m${VPS_IP}\033[0m"
echo -e "  脚本状态 : ${SCRIPT_STATUS}"
echo -e "  Xray内核 : ${XRAY_STATUS}"
echo "-----------------------------------------------------"
echo "  1. 一键安装 / 覆盖更新 (VLESS-xhttp + Hysteria2)"
echo "  2. 一键完全卸载 (清理所有配置与进程)"
echo "  0. 退出"
echo "====================================================="
read -p "请输入对应数字进行操作: " MENU_CHOICE

case $MENU_CHOICE in
    1)
        install
        ;;
    2)
        read -p "⚠️ 确认要彻底卸载并删除所有数据吗？(y/n): " CONFIRM
        if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
            uninstall
        else
            echo "已取消卸载。"
            exit 0
        fi
        ;;
    0)
        exit 0
        ;;
    *)
        echo "无效输入，已退出。"
        exit 1
        ;;
esac