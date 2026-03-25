#!/bin/bash
set -uo pipefail

# ============================================================
# AnyTLS-Go 一键安装管理脚本 (优化版)
# 基于 https://github.com/tianrking/AnyTLS-Go-Script 优化
# 支持: Ubuntu / Debian / CentOS / RHEL / Fedora
# 特性: 自动获取最新版本 / 随机密码 / 订阅链接 / 二维码
# ============================================================

GITHUB_REPO="anytls/anytls-go"
SCRIPT_REPO="https://raw.githubusercontent.com/Mike09811/AnyTLS-Installer/main/install.sh"
INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="anytls-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SUB_SERVICE_NAME="anytls-sub"
SUB_SERVICE_FILE="/etc/systemd/system/${SUB_SERVICE_NAME}.service"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/config"
SUB_SCRIPT="${CONFIG_DIR}/sub_server.py"
SCRIPT_NAME="anytls"

# SNI 伪装域名列表
SNI_DOMAINS=(
    "www.microsoft.com"
    "www.apple.com"
    "www.amazon.com"
    "www.cloudflare.com"
    "www.mozilla.org"
    "www.github.com"
    "www.bing.com"
    "www.office.com"
    "www.xbox.com"
    "www.linkedin.com"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
hint()  { echo -e "${CYAN}$*${NC}"; }

# --- 工具函数 ---

check_command() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ $(id -u) -ne 0 ]] && error "此操作需要 root 权限，请使用 sudo ${SCRIPT_NAME} $1"
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) error "不支持的架构: $(uname -m)" ;;
    esac
}

install_deps() {
    local deps=()
    check_command curl     || deps+=("curl")
    check_command unzip    || deps+=("unzip")
    check_command python3  || deps+=("python3")
    check_command qrencode || deps+=("qrencode")

    [[ ${#deps[@]} -eq 0 ]] && return 0

    info "安装依赖: ${deps[*]}"
    if check_command apt-get; then
        apt-get update -qq && apt-get install -y -qq "${deps[@]}"
    elif check_command dnf; then
        dnf install -y -q "${deps[@]}"
    elif check_command yum; then
        yum install -y -q "${deps[@]}"
    else
        error "无法识别包管理器，请手动安装: ${deps[*]}"
    fi
}

get_latest_version() {
    local version
    version=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$version" ]] && error "无法获取最新版本号，请检查网络"
    echo "$version"
}

get_public_ip() {
    local ip=""
    for src in "https://api.ipify.org" "https://ipinfo.io/ip" "https://checkip.amazonaws.com" "https://icanhazip.com"; do
        ip=$(curl -s --max-time 5 --ipv4 "$src" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"; return 0
        fi
    done
    echo ""; return 1
}

pick_random_sni() {
    local count=${#SNI_DOMAINS[@]}
    local idx=$((RANDOM % count))
    echo "${SNI_DOMAINS[$idx]}"
}

# --- BBR + 内核网络优化 ---

enable_bbr() {
    info "检测 BBR 状态..."

    # 检查当前是否已启用 BBR
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        info "BBR 已启用，跳过"
    else
        # 检查内核是否支持 BBR (4.9+)
        local kver
        kver=$(uname -r | cut -d. -f1-2)
        local kmajor kminor
        kmajor=$(echo "$kver" | cut -d. -f1)
        kminor=$(echo "$kver" | cut -d. -f2)

        if (( kmajor < 4 )) || { (( kmajor == 4 )) && (( kminor < 9 )); }; then
            warn "内核版本 $(uname -r) 不支持 BBR (需要 4.9+)，跳过"
            return
        fi

        info "启用 BBR..."
        modprobe tcp_bbr 2>/dev/null || true

        # 写入 sysctl 配置
        cat > /etc/sysctl.d/99-anytls-bbr.conf <<'SYSEOF'
# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 优化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

# 缓冲区优化
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 212992 16777216
net.ipv4.tcp_wmem = 4096 212992 16777216
net.core.netdev_max_backlog = 10000

# 连接优化
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_mtu_probing = 1

# 文件描述符
fs.file-max = 1048576
SYSEOF

        sysctl --system > /dev/null 2>&1

        # 验证
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        if [[ "$current_cc" == "bbr" ]]; then
            info "BBR 启用成功"
        else
            warn "BBR 启用失败，当前拥塞控制: $current_cc"
        fi
    fi

    # 显示状态
    local qdisc cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    info "拥塞控制: $cc | 队列调度: $qdisc"
}

generate_random_password() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }
generate_sub_token()       { tr -dc 'a-z0-9' < /dev/urandom | head -c 32; }

urlencode() {
    local string="$1" strlen=${#1} encoded="" pos c o
    for (( pos=0; pos<strlen; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9]) o="$c" ;;
            *) printf -v o '%%%02x' "'$c" ;;
        esac
        encoded+="$o"
    done
    echo "$encoded"
}

show_qr() {
    local text="$1"
    if check_command qrencode; then
        qrencode -t ANSIUTF8 -m 1 "$text"
    fi
}

install_management_script() {
    info "安装管理脚本到 ${INSTALL_DIR}/${SCRIPT_NAME} ..."
    curl -fsSL -o "${INSTALL_DIR}/${SCRIPT_NAME}" "$SCRIPT_REPO" || {
        # fallback: 尝试从本地复制
        local self_script
        self_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")
        if [[ -n "$self_script" && -f "$self_script" ]]; then
            cp "$self_script" "${INSTALL_DIR}/${SCRIPT_NAME}"
        else
            warn "无法安装管理脚本，请手动下载"
            return 1
        fi
    }
    chmod 755 "${INSTALL_DIR}/${SCRIPT_NAME}"
    info "管理脚本已安装，可直接使用 ${SCRIPT_NAME} 命令"
}

# --- 订阅服务 ---

create_sub_server() {
    local ip="$1" port="$2" password="$3" sub_port="$4" sub_token="$5" sni="$6"

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
SERVER_IP=${ip}
SERVER_PORT=${port}
PASSWORD=${password}
SUB_PORT=${sub_port}
SUB_TOKEN=${sub_token}
SNI=${sni}
EOF
    chmod 600 "$CONFIG_FILE"

    cat > "$SUB_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import http.server
import base64
import json
import urllib.parse

CONFIG_FILE = "/etc/anytls/config"

def load_config():
    cfg = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                cfg[k] = v
    return cfg

def url_encode(s):
    return urllib.parse.quote(s, safe='')

class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        cfg = load_config()
        token = cfg.get("SUB_TOKEN", "")
        ip = cfg.get("SERVER_IP", "")
        port = cfg.get("SERVER_PORT", "")
        password = cfg.get("PASSWORD", "")
        sni = cfg.get("SNI", "www.microsoft.com")
        encoded_pw = url_encode(password)
        node_name = url_encode(f"AnyTLS-{port}")

        path_clean = self.path.split("?")[0].rstrip("/")
        if path_clean != f"/sub/{token}":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not Found")
            return

        query = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(query)
        client_type = params.get("client", [""])[0].lower()

        anytls_uri = f"anytls://{encoded_pw}@{ip}:{port}?sni={url_encode(sni)}&insecure=1#{node_name}"

        if client_type in ("clash", "mihomo"):
            content = self._clash_config(ip, port, password, sni)
            ctype = "text/yaml; charset=utf-8"
        elif client_type in ("singbox", "sing-box"):
            content = self._singbox_config(ip, port, password, sni)
            ctype = "application/json; charset=utf-8"
        else:
            content = base64.b64encode(anytls_uri.encode()).decode()
            ctype = "text/plain; charset=utf-8"

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Disposition", f"attachment; filename=anytls_{port}")
        self.send_header("Subscription-Userinfo", "upload=0; download=0; total=0; expire=0")
        self.end_headers()
        self.wfile.write(content.encode())

    def _clash_config(self, ip, port, password, sni):
        return f"""proxies:
  - name: AnyTLS-{port}
    type: anytls
    server: {ip}
    port: {port}
    password: "{password}"
    sni: {sni}
    skip-cert-verify: true

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - AnyTLS-{port}

rules:
  - MATCH,Proxy
"""

    def _singbox_config(self, ip, port, password, sni):
        config = {
            "outbounds": [{
                "type": "anytls",
                "tag": f"AnyTLS-{port}",
                "server": ip,
                "server_port": int(port),
                "password": password,
                "tls": {
                    "enabled": True,
                    "insecure": True,
                    "server_name": sni
                }
            }]
        }
        return json.dumps(config, indent=2, ensure_ascii=False)

if __name__ == "__main__":
    cfg = load_config()
    sub_port = int(cfg.get("SUB_PORT", 8444))
    server = http.server.HTTPServer(("0.0.0.0", sub_port), SubHandler)
    print(f"Subscription server running on port {sub_port}")
    server.serve_forever()
PYEOF

    chmod 755 "$SUB_SCRIPT"

    cat > "$SUB_SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS Subscription Server
After=network.target

[Service]
Type=simple
ExecStart=$(which python3) ${SUB_SCRIPT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SUB_SERVICE_NAME" > /dev/null 2>&1
    systemctl restart "$SUB_SERVICE_NAME"
}

# --- 安装 ---

do_install() {
    require_root "install"

    echo ""
    echo "========================================="
    info "AnyTLS-Go 安装/更新"
    echo "========================================="
    echo ""

    # 端口
    read -rp "请输入监听端口 (默认 8443): " input_port
    local port="${input_port:-8443}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        error "端口号无效: $port"
    fi

    # 订阅端口
    local default_sub_port=$((port + 1))
    read -rp "请输入订阅服务端口 (默认 ${default_sub_port}): " input_sub_port
    local sub_port="${input_sub_port:-$default_sub_port}"
    if ! [[ "$sub_port" =~ ^[0-9]+$ ]] || (( sub_port < 1 || sub_port > 65535 )); then
        error "订阅端口号无效: $sub_port"
    fi

    # 密码
    local password
    read -rs -p "请输入密码 (直接回车随机生成): " password; echo
    if [[ -z "$password" ]]; then
        password=$(generate_random_password)
        info "已生成随机密码: $password"
    fi

    # SNI
    local sni
    sni=$(pick_random_sni)
    read -rp "请输入 SNI 伪装域名 (默认 ${sni}): " input_sni
    sni="${input_sni:-$sni}"

    # 依赖
    install_deps

    # BBR + 网络优化
    enable_bbr

    # 架构 & 版本
    local arch version
    arch=$(get_arch)
    info "系统架构: $arch"

    version=$(get_latest_version)
    info "最新版本: $version"

    # 下载
    local ver_num="${version#v}"
    local filename="anytls_${ver_num}_linux_${arch}.zip"
    local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${filename}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" EXIT

    info "下载 $url ..."
    curl -fsSL -o "${tmp_dir}/${filename}" "$url" || error "下载失败"

    info "解压中..."
    unzip -o "${tmp_dir}/${filename}" -d "${tmp_dir}" > /dev/null || error "解压失败"

    # 停止旧服务
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl stop "$SUB_SERVICE_NAME" 2>/dev/null || true

    # 安装二进制
    for bin in anytls-server anytls-client; do
        if [[ -f "${tmp_dir}/${bin}" ]]; then
            install -m 755 "${tmp_dir}/${bin}" "${INSTALL_DIR}/${bin}"
            info "已安装 ${INSTALL_DIR}/${bin}"
        fi
    done

    # 安装管理脚本
    install_management_script

    # systemd 服务
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS Server (${version})
Documentation=https://github.com/anytls/anytls-go
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${port} -p ${password}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    # 订阅服务
    local server_ip sub_token
    server_ip=$(get_public_ip) || server_ip="YOUR_SERVER_IP"
    sub_token=$(generate_sub_token)
    create_sub_server "$server_ip" "$port" "$password" "$sub_port" "$sub_token" "$sni"

    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo ""
        info "AnyTLS 安装成功并已启动"
        echo ""
        show_connection_info "$server_ip" "$port" "$password" "$sub_port" "$sub_token" "$sni"
        echo ""
        display_manage_commands
    else
        error "服务启动失败，请查看日志: journalctl -u $SERVICE_NAME -n 20"
    fi
}

# --- 卸载 ---

do_uninstall() {
    require_root "uninstall"
    info "正在卸载 AnyTLS-Go..."

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    systemctl stop "$SUB_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SUB_SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$SUB_SERVICE_FILE"
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    rm -f "${INSTALL_DIR}/anytls-server" "${INSTALL_DIR}/anytls-client" "${INSTALL_DIR}/${SCRIPT_NAME}"
    rm -rf "$CONFIG_DIR"
    rm -f /etc/sysctl.d/99-anytls-bbr.conf
    sysctl --system > /dev/null 2>&1 || true

    info "卸载完成"
}

# --- 服务管理 ---

do_start()   { require_root "start";   systemctl start "$SERVICE_NAME"; systemctl start "$SUB_SERVICE_NAME"; sleep 1; do_status; }
do_stop()    { require_root "stop";    systemctl stop "$SERVICE_NAME"; systemctl stop "$SUB_SERVICE_NAME"; sleep 1; do_status; }
do_restart() { require_root "restart"; systemctl restart "$SERVICE_NAME"; systemctl restart "$SUB_SERVICE_NAME"; sleep 1; do_status; }
do_status()  { systemctl status "$SERVICE_NAME" --no-pager; echo ""; systemctl status "$SUB_SERVICE_NAME" --no-pager; }
do_log()     { journalctl -u "$SERVICE_NAME" -f "$@"; }

# --- 信息展示 ---

show_connection_info() {
    local ip="$1" port="$2" password="$3" sub_port="$4" sub_token="$5" sni="$6"
    local sub_url="http://${ip}:${sub_port}/sub/${sub_token}"

    echo "==========================================="
    echo ""
    hint "  【订阅链接 - 通用】(Shadowrocket / NekoBox / 通用客户端)"
    echo "  ${sub_url}"
    show_qr "$sub_url"
    echo ""
    hint "  【订阅链接 - Clash / Mihomo】"
    echo "  ${sub_url}?client=clash"
    show_qr "${sub_url}?client=clash"
    echo ""
    hint "  【订阅链接 - sing-box】"
    echo "  ${sub_url}?client=singbox"
    show_qr "${sub_url}?client=singbox"
    echo ""
    echo "==========================================="
    echo ""
    echo "  服务器地址 : $ip"
    echo "  服务器端口 : $port"
    echo "  密码       : $password"
    echo "  SNI        : $sni"
    echo "  订阅端口   : $sub_port"
    echo "  协议       : AnyTLS"
    echo "  允许不安全 : 已自动开启 (insecure=1)"
    echo "  BBR        : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo "-----------------------------------------------"
}

do_info() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "未找到配置，请先运行: sudo ${SCRIPT_NAME} install"
    fi

    source "$CONFIG_FILE"
    local ip="${SERVER_IP:-}"
    local port="${SERVER_PORT:-}"
    local password="${PASSWORD:-}"
    local sub_port="${SUB_PORT:-}"
    local sub_token="${SUB_TOKEN:-}"
    local sni="${SNI:-www.microsoft.com}"

    [[ -z "$ip" ]] && ip=$(get_public_ip) || true

    echo ""
    show_connection_info "$ip" "$port" "$password" "$sub_port" "$sub_token" "$sni"
}

display_manage_commands() {
    echo "【管理命令】"
    echo "  sudo ${SCRIPT_NAME} install    安装/更新"
    echo "  sudo ${SCRIPT_NAME} uninstall  卸载"
    echo "  sudo ${SCRIPT_NAME} start      启动"
    echo "  sudo ${SCRIPT_NAME} stop       停止"
    echo "  sudo ${SCRIPT_NAME} restart    重启"
    echo "       ${SCRIPT_NAME} status     状态"
    echo "       ${SCRIPT_NAME} log        日志 (可加 -n 50)"
    echo "       ${SCRIPT_NAME} info       显示订阅链接"
    echo "       ${SCRIPT_NAME} bbr        启用 BBR 加速"
    echo "       ${SCRIPT_NAME} help       帮助"
    echo "-----------------------------------------------"
}

show_help() {
    echo ""
    echo "AnyTLS-Go 一键管理脚本 (优化版)"
    echo ""
    echo "用法: ${SCRIPT_NAME} <命令>"
    echo ""
    printf "  %-12s %s\n" "install"   "安装或更新 AnyTLS-Go (需要 sudo)"
    printf "  %-12s %s\n" "uninstall" "卸载 AnyTLS-Go (需要 sudo)"
    printf "  %-12s %s\n" "start"     "启动服务 (需要 sudo)"
    printf "  %-12s %s\n" "stop"      "停止服务 (需要 sudo)"
    printf "  %-12s %s\n" "restart"   "重启服务 (需要 sudo)"
    printf "  %-12s %s\n" "status"    "查看服务状态"
    printf "  %-12s %s\n" "log"       "查看日志 (如: ${SCRIPT_NAME} log -n 100)"
    printf "  %-12s %s\n" "info"      "显示订阅链接和配置信息"
    printf "  %-12s %s\n" "bbr"       "启用 BBR 拥塞控制 + 内核网络优化 (需要 sudo)"
    printf "  %-12s %s\n" "help"      "显示帮助"
    echo ""
}

# --- 主入口 ---

main() {
    local action="${1:-help}"
    shift 2>/dev/null || true

    case "$action" in
        install)                do_install ;;
        uninstall)              do_uninstall ;;
        start)                  do_start ;;
        stop)                   do_stop ;;
        restart)                do_restart ;;
        status)                 do_status ;;
        log)                    do_log "$@" ;;
        info)                   do_info ;;
        bbr)                    require_root "bbr"; enable_bbr ;;
        help|-h|--help|"")      show_help ;;
        *) error "未知命令: $action (运行 ${SCRIPT_NAME} help 查看帮助)" ;;
    esac
}

main "$@"
