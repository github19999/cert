#!/bin/bash
set -e

# ========= [ 颜色定义 ] =========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

SCRIPT_VERSION="1.1"
STOPPED_SERVICES=(); DOMAINS=(); MAIN_DOMAIN=""; CERT_DIR=""; OS=""; INSTALL_CMD=""; UPDATE_CMD=""

# ========= [ 日志函数 ] =========
log_info(){ echo -e "${BLUE}[INFO]${NC} $1"; }
log_success(){ echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning(){ echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $1"; }
log_step(){ echo -e "${PURPLE}[STEP]${NC} $1"; }

# ========= [ IPv6 检测函数 ] =========
check_ipv6_only() {
    if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && ping6 -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1; then
        return 0  # 仅 IPv6
    fi
    return 1
}

# ========= [ 网络检测优化版 ] =========
check_network() {
    log_step "检查网络连接..."
    local network_ok=false

    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log_info "IPv4 网络连接正常"
        network_ok=true
    elif ping6 -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1; then
        log_info "IPv6 网络连接正常"
        network_ok=true
    fi

    if [[ $network_ok == false ]]; then
        log_error "网络连接失败，请检查网络配置（无 IPv4 或 IPv6）"
        exit 1
    fi

    # DNS 检查
    if ! nslookup google.com >/dev/null 2>&1; then
        if dig -6 google.com AAAA +short >/dev/null 2>&1; then
            log_success "IPv6 DNS 解析正常"
        else
            log_warning "DNS 解析可能异常"
        fi
    fi
    log_success "网络连接检测完成"
}

# ========= [ 其他函数保持原逻辑 ] =========
# ...（detect_os, configure_domains, configure_cert_path, manage_web_services, install_dependencies, install_acme_client 等全部不变）...

# ========= [ SSL证书申请部分修改 ] =========
request_ssl_certificate() {
    log_step "申请SSL证书..."

    manage_web_services "stop"
    local domain_args=""
    for domain in "${DOMAINS[@]}"; do
        domain_args="$domain_args -d $domain"
    done

    if check_ipv6_only; then
        log_info "检测到仅 IPv6 环境，使用 IPv6 standalone 模式"
        /root/.acme.sh/acme.sh --issue $domain_args --standalone --listen-v6 --force
    else
        /root/.acme.sh/acme.sh --issue $domain_args --standalone --force
    fi

    if [[ $? -eq 0 ]]; then
        log_success "SSL证书申请成功！"
    else
        log_error "SSL证书申请失败"
        manage_web_services "start"
        exit 1
    fi
}

# ========= [ 其余函数与原脚本相同，不需更改 ] =========
# install_ssl_certificate, setup_certificate_permissions, setup_auto_renewal, show_completion_info, cleanup_on_error, main 全部保持不变。

# ========= [ 主函数入口 ] =========
main() {
    trap cleanup_on_error INT TERM
    show_banner
    check_root
    check_network
    detect_os
    configure_domains
    configure_cert_path
    install_dependencies
    install_acme_client
    request_ssl_certificate
    install_ssl_certificate
    setup_auto_renewal
    manage_web_services "start"
    show_completion_info
}

main "$@"
