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
        SCRIPT_STATUS="\033[31m未安装\033[0m"
    fi

    # 3. 检查 Xray 状态、版本与更新
    if [ -f "/usr/local/bin/xray" ]; then
        LOCAL_XRAY_VER=$(/usr/local/bin/xray version | head -n1 | awk '{print $2}')
        LOCAL_CLEAN=${LOCAL_XRAY_VER#v}
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
    
    rm -rf /root/.acme.sh/
    
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
    if ! grep -Rqs "^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "\033[32m[+] BBR 加速已成功开启。\033[0m"
    else
        sysctl -p >/dev/null 2>&1
        echo -e "\033[32m[+] BBR 已经处于配置状态。\033[0m"
    fi

    echo "[*] 正在安装基础环境依赖..."
    apt update || { echo -e "\033[31m[-] apt update 失败，安装中止。\033[0m"; exit 1; }
    apt install -y curl wget socat jq openssl python3 || { echo -e "\033[31m[-] apt install 失败，安装中止。\033[0m"; exit 1; }

    # 修改为 Xray 有权访问的目录
    mkdir -p /usr/local/etc/xray
    CERT_FILE="/usr/local/etc/xray/server.cer"
    KEY_FILE="/usr/local/etc/xray/server.key"

    if [ "$CERT_MODE" == "1" ]; then
        read -p "请输入已解析的域名 (如 proxy.example.com): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo "域名不能为空，退出。"
            exit 1
        fi
        
        echo "[*] 正在通过 acme.sh 申请证书 (需 80 端口放行)..."
        if ! curl -fsSL --max-time 15 https://get.acme.sh | sh -s email="admin@$DOMAIN"; then
            echo -e "\033[31m[-] acme.sh 安装失败，安装中止。\033[0m"
            exit 1
        fi
        source ~/.bashrc

        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone || {
            echo -e "\033[31m[-] 证书申请失败，安装中止。\033[0m"
            exit 1
        }

        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file       $KEY_FILE  \
        --fullchain-file $CERT_FILE \
        --reloadcmd     "systemctl restart xray && systemctl restart hysteria-server"

        HOST_ADDRESS=$DOMAIN
        SNI=$DOMAIN
    else
        DEFAULT_IP=$(curl -s -4 -m 5 https://api.ipify.org)
        if [ -z "$DEFAULT_IP" ]; then
            echo -e "\033[33m[!] 无法自动获取公网 IP，请手动输入。\033[0m"
        fi
        read -p "请输入本机公网 IP (默认: $DEFAULT_IP): " SERVER_IP
        SERVER_IP=${SERVER_IP:-$DEFAULT_IP}
        if [ -z "$SERVER_IP" ]; then
            echo -e "\033[31m[-] 未提供有效公网 IP，安装中止。\033[0m"
            exit 1
        fi
        
        echo "[*] 正在生成 10 年期自签证书..."
        SNI="www.bing.com"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout $KEY_FILE \
            -out $CERT_FILE \
            -subj "/C=US/ST=CA/L=LosAngeles/O=Microsoft/CN=$SNI" >/dev/null 2>&1
            
        HOST_ADDRESS=$SERVER_IP
    fi

    # 【极其关键】赋予 Xray 读取证书的权限，防止进程崩溃
    chown nobody:nogroup "$CERT_FILE" "$KEY_FILE"
    chmod 644 "$CERT_FILE" "$KEY_FILE"

    echo "[*] 正在部署/更新 Xray-core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [ "1.1.1.1", "8.8.8.8", "localhost" ]
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

    echo "[*] 正在部署/更新 Hysteria2..."
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

    mkdir -p "/opt/sub_server/$SUB_PATH"
    printf '%s\n%s' "$VLESS_LINK" "$HY2_LINK" | base64 | tr -d '\n' > "/opt/sub_server/$SUB_PATH/index.html"

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

    echo "[*] 正在将管理菜单写入系统快捷命令..."
    TMP_SCRIPT=$(mktemp)
    if ! curl -fsSL --max-time 10 "$SCRIPT_URL" -o "$TMP_SCRIPT"; then
        rm -f "$TMP_SCRIPT"
        echo -e "\033[31m[-] 下载最新脚本失败，安装中止。\033[0m"
        exit 1
    fi
    if [ -f /usr/local/bin/xx ] && cmp -s "$TMP_SCRIPT" /usr/local/bin/xx; then
        echo -e "\033[32m[+] 当前脚本已是最新版本，跳过更新。\033[0m"
    else
        if [ -f /usr/local/bin/xx ]; then
            ACTION_DESC="更新"
        else
            ACTION_DESC="安装"
        fi
        install -m 755 "$TMP_SCRIPT" /usr/local/bin/xx || {
            rm -f "$TMP_SCRIPT"
            echo -e "\033[31m[-] 写入快捷命令失败，安装中止。\033[0m"
            exit 1
        }
        echo -e "\033[32m[+] 管理脚本${ACTION_DESC}完成。\033[0m"
    fi
    rm -f "$TMP_SCRIPT"

    clear
    echo "====================================================="
    echo -e "\033[32m                  部署全部完成！                     \033[0m"
    echo "====================================================="
    echo "【你的私密订阅链接】(直接复制到客户端更新订阅)"
    echo -e "🔗 \033[36mhttp://${HOST_ADDRESS}:${SUB_PORT}/${SUB_PATH}/\033[0m"
    echo "====================================================="
    echo -e "\033[33m💡 提示: 脚本已不再干预防火墙设置。\033[0m"
    echo -e "\033[33m   如果出现超时连不上，请确保你的系统环境和云服务商\033[0m"
    echo -e "\033[33m   安全组已经手动放行了以下端口：\033[0m"
    echo -e "\033[33m   TCP: 80 (仅申请证书时用), $XRAY_PORT, $SUB_PORT\033[0m"
    echo -e "\033[33m   UDP: $XRAY_PORT, $HY2_PORT\033[0m"
    echo "====================================================="
}

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
