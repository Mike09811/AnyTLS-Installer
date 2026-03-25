#!/bin/bash
set -uo pipefail

# ============================================================
# AnyTLS-Go 一键安装管理脚本 (优化版)
# 基于 https://github.com/tianrking/AnyTLS-Go-Script 优化
# 支持: Ubuntu / Debian / CentOS / RHEL / Fedora
# ============================================================

GITHUB_REPO="anytls/anytls-go"
INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="anytls-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_NAME="anytls"

# --- 颜色 ---
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
    check_command curl    || deps+=("curl")
    check_command unzip   || deps+=("unzip")
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
    local sources=(
        "https://api.ipify.org"
        "https://ipinfo.io/ip"
        "https://checkip.amazonaws.com"
        "https://icanhazip.com"
    )
    for src in "${sources[@]}"; do
        ip=$(curl -s --max-time 5 --ipv4 "$src" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
    return 1
}

generate_random_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

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

    # 密码
    local password
    read -rs -p "请输入密码 (直接回车随机生成): " password; echo
    if [[ -z "$password" ]]; then
        password=$(generate_random_password)
        info "已生成随机密码: $password"
    fi

    # 依赖
    install_deps

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
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
    fi

    # 安装二进制
    for bin in anytls-server anytls-client; do
        if [[ -f "${tmp_dir}/${bin}" ]]; then
            install -m 755 "${tmp_dir}/${bin}" "${INSTALL_DIR}/${bin}"
            info "已安装 ${INSTALL_DIR}/${bin}"
        fi
    done

    # 安装管理脚本自身
    local self_script
    self_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")
    if [[ -n "$self_script" && -f "$self_script" ]]; then
        install -m 755 "$self_script" "${INSTALL_DIR}/${SCRIPT_NAME}"
        info "管理脚本已安装到 ${INSTALL_DIR}/${SCRIPT_NAME}"
    fi

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

    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo ""
        info "AnyTLS 服务安装成功并已启动"
        echo ""
        local server_ip
        server_ip=$(get_public_ip) || server_ip="YOUR_SERVER_IP"
        show_connection_info "$server_ip" "$port" "$password"
        generate_qr_codes "$server_ip" "$port" "$password"
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
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    rm -f "${INSTALL_DIR}/anytls-server" "${INSTALL_DIR}/anytls-client" "${INSTALL_DIR}/${SCRIPT_NAME}"

    info "卸载完成"
}

# --- 服务管理 ---

do_start()   { require_root "start";   systemctl start   "$SERVICE_NAME"; sleep 1; do_status; }
do_stop()    { require_root "stop";    systemctl stop    "$SERVICE_NAME"; sleep 1; do_status; }
do_restart() { require_root "restart"; systemctl restart "$SERVICE_NAME"; sleep 1; do_status; }
do_status()  { systemctl status "$SERVICE_NAME" --no-pager; }
do_log()     { journalctl -u "$SERVICE_NAME" -f "$@"; }

# --- 信息展示 ---

show_connection_info() {
    local ip="$1" port="$2" password="$3"
    echo "-----------------------------------------------"
    echo "  服务器地址 : $ip"
    echo "  服务器端口 : $port"
    echo "  密码       : $password"
    echo "  协议       : AnyTLS"
    echo "  注意       : 使用自签名证书，客户端需开启「允许不安全」"
    echo "-----------------------------------------------"
}

generate_qr_codes() {
    local ip="$1" port="$2" password="$3"

    if ! check_command qrencode; then
        warn "未安装 qrencode，跳过二维码生成"
        return
    fi

    local encoded_pw remarks
    encoded_pw=$(urlencode "$password")
    remarks=$(urlencode "AnyTLS-${port}")

    # NekoBox
    local neko_uri="anytls://${encoded_pw}@${ip}:${port}?allowInsecure=true#${remarks}"
    echo ""
    hint "【NekoBox 链接】"
    echo "$neko_uri"
    qrencode -t ANSIUTF8 -m 1 "$neko_uri"

    # Shadowrocket
    local sr_uri="anytls://${encoded_pw}@${ip}:${port}#${remarks}"
    echo ""
    hint "【Shadowrocket 链接】"
    echo "$sr_uri"
    qrencode -t ANSIUTF8 -m 1 "$sr_uri"
    echo "提醒: Shadowrocket 扫码后请手动开启「允许不安全」"
    echo "-----------------------------------------------"
}

do_qr() {
    [[ ! -f "$SERVICE_FILE" ]] && error "AnyTLS 尚未安装，请先运行: sudo ${SCRIPT_NAME} install"

    install_deps

    local port
    port=$(grep -Po 'ExecStart=.*-l 0\.0\.0\.0:\K[0-9]+' "$SERVICE_FILE" 2>/dev/null)
    if [[ -z "$port" ]]; then
        read -rp "请输入当前配置的端口: " port
        [[ ! "$port" =~ ^[0-9]+$ ]] && error "端口号无效"
    else
        info "读取到端口: $port"
    fi

    local password
    read -rs -p "请输入密码: " password; echo
    [[ -z "$password" ]] && error "密码不能为空"

    local ip
    ip=$(get_public_ip) || ip="YOUR_SERVER_IP"

    show_connection_info "$ip" "$port" "$password"
    generate_qr_codes "$ip" "$port" "$password"
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
    echo "       ${SCRIPT_NAME} qr         显示二维码"
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
    printf "  %-12s %s\n" "qr"        "重新生成二维码"
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
        qr)                     do_qr ;;
        help|-h|--help|"")      show_help ;;
        *) error "未知命令: $action (运行 ${SCRIPT_NAME} help 查看帮助)" ;;
    esac
}

main "$@"
