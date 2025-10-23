#!/bin/bash

# SSL证书一键部署脚本 (支持IPv6)
# 文件名: deploy-cert.sh
# 作者: github19999
# 版本: 1.1 (IPv6增强版)
# 使用方法: bash <(curl -sSL https://raw.githubusercontent.com/用户名/cert/refs/heads/main/deploy-cert.sh)

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_VERSION="1.1"
STOPPED_SERVICES=()
DOMAINS=()
MAIN_DOMAIN=""
CERT_DIR=""
OS=""
INSTALL_CMD=""
UPDATE_CMD=""
HAS_IPV4=false
HAS_IPV6=false
NETWORK_MODE=""  # "ipv4", "ipv6", "dual"

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}

# 显示脚本标题
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "=============================================="
    echo "   SSL证书一键部署脚本 v${SCRIPT_VERSION}"
    echo "          (支持IPv4/IPv6双栈)"
    echo "=============================================="
    echo -e "${NC}"
    echo -e "${YELLOW}功能特性:${NC}"
    echo "  ✓ 交互式域名配置"
    echo "  ✓ 多域名证书支持"
    echo "  ✓ 智能服务管理"
    echo "  ✓ IPv4/IPv6自动检测"
    echo "  ✓ 纯IPv6环境支持"
    echo "  ✓ 系统兼容性检测"
    echo "  ✓ 完善错误处理"
    echo "  ✓ 自动续期设置"
    echo "  ✓ 安全权限配置"
    echo ""
    echo -e "${GREEN}支持系统: Ubuntu/Debian, CentOS/RHEL${NC}"
    echo ""
}

# 检查Root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        echo -e "${YELLOW}请使用以下命令重新运行:${NC}"
        echo "sudo bash <(curl -sSL https://raw.githubusercontent.com/用户名/cert/refs/heads/main/deploy-cert.sh)"
        exit 1
    fi
    log_success "Root权限检查通过"
}

# 检测网络类型 (IPv4/IPv6)
detect_network_type() {
    log_step "检测网络类型..."
    
    # 检测IPv4
    if ip -4 addr show | grep -q "inet.*scope global" 2>/dev/null; then
        HAS_IPV4=true
        log_info "检测到IPv4地址"
    fi
    
    # 检测IPv6
    if ip -6 addr show | grep -q "inet6.*scope global" 2>/dev/null; then
        HAS_IPV6=true
        log_info "检测到IPv6地址"
    fi
    
    # 确定网络模式
    if [[ $HAS_IPV4 == true && $HAS_IPV6 == true ]]; then
        NETWORK_MODE="dual"
        log_success "网络类型: IPv4/IPv6 双栈"
    elif [[ $HAS_IPV4 == true ]]; then
        NETWORK_MODE="ipv4"
        log_success "网络类型: 仅IPv4"
    elif [[ $HAS_IPV6 == true ]]; then
        NETWORK_MODE="ipv6"
        log_success "网络类型: 仅IPv6"
        log_warning "检测到纯IPv6环境，将使用IPv6专用配置"
    else
        log_error "未检测到可用的网络连接"
        exit 1
    fi
}

# 检查网络连接 (支持IPv6)
check_network() {
    log_step "检查网络连接..."
    
    local network_ok=false
    
    if [[ $NETWORK_MODE == "ipv4" || $NETWORK_MODE == "dual" ]]; then
        # IPv4连接测试
        local ipv4_hosts=("8.8.8.8" "1.1.1.1" "114.114.114.114")
        for host in "${ipv4_hosts[@]}"; do
            if ping -4 -c 1 -W 3 "$host" >/dev/null 2>&1; then
                network_ok=true
                log_info "IPv4连接正常"
                break
            fi
        done
    fi
    
    if [[ $NETWORK_MODE == "ipv6" || $NETWORK_MODE == "dual" ]]; then
        # IPv6连接测试
        local ipv6_hosts=("2001:4860:4860::8888" "2606:4700:4700::1111" "2400:3200::1")
        for host in "${ipv6_hosts[@]}"; do
            if ping -6 -c 1 -W 3 "$host" >/dev/null 2>&1; then
                network_ok=true
                log_info "IPv6连接正常"
                break
            fi
        done
    fi
    
    if [[ $network_ok == false ]]; then
        log_error "网络连接失败，请检查网络配置"
        exit 1
    fi
    
    # DNS解析测试 (适配IPv6)
    local dns_test_domain="google.com"
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        # 纯IPv6环境，测试AAAA记录
        if nslookup -query=AAAA "$dns_test_domain" >/dev/null 2>&1 || \
           host -t AAAA "$dns_test_domain" >/dev/null 2>&1; then
            log_info "DNS解析正常 (IPv6)"
        else
            log_warning "IPv6 DNS解析可能存在问题"
        fi
    else
        # IPv4或双栈环境
        if nslookup "$dns_test_domain" >/dev/null 2>&1; then
            log_info "DNS解析正常"
        else
            log_warning "DNS解析可能存在问题"
        fi
    fi
    
    log_success "网络连接检查完成"
}

# 检测操作系统
detect_os() {
    log_step "检测操作系统..."
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case $ID in
            ubuntu|debian)
                OS="debian"
                INSTALL_CMD="apt-get install -y"
                UPDATE_CMD="apt-get update"
                log_info "检测到系统: $PRETTY_NAME"
                ;;
            centos|rhel|fedora)
                OS="centos"
                INSTALL_CMD="yum install -y"
                UPDATE_CMD="yum makecache"
                log_info "检测到系统: $PRETTY_NAME"
                ;;
            *)
                log_error "不支持的操作系统: $PRETTY_NAME"
                exit 1
                ;;
        esac
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"
        INSTALL_CMD="apt-get install -y"
        UPDATE_CMD="apt-get update"
        log_info "检测到系统: Debian/Ubuntu"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
        INSTALL_CMD="yum install -y"
        UPDATE_CMD="yum makecache"
        log_info "检测到系统: CentOS/RHEL"
    else
        log_error "无法识别操作系统"
        exit 1
    fi
    
    log_success "系统检测完成: $OS"
}

# 检查域名解析 (支持IPv6)
check_domain_resolution() {
    local domain=$1
    local resolution_ok=false
    
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        # 纯IPv6环境，检查AAAA记录
        if nslookup -query=AAAA "$domain" >/dev/null 2>&1 || \
           host -t AAAA "$domain" >/dev/null 2>&1 || \
           dig AAAA "$domain" +short >/dev/null 2>&1; then
            resolution_ok=true
        fi
    else
        # IPv4或双栈环境，检查A记录
        if nslookup "$domain" >/dev/null 2>&1 || \
           host "$domain" >/dev/null 2>&1 || \
           dig "$domain" +short >/dev/null 2>&1; then
            resolution_ok=true
        fi
    fi
    
    if [[ $resolution_ok == true ]]; then
        return 0
    else
        return 1
    fi
}

# 交互式域名配置
configure_domains() {
    log_step "配置SSL证书域名..."
    
    echo -e "${CYAN}请配置要申请SSL证书的域名:${NC}"
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  • 支持单个或多个域名"
    echo "  • 多个域名请用空格分隔"
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        echo "  • ${RED}当前为IPv6环境，请确保域名有AAAA记录${NC}"
    else
        echo "  • 确保域名已正确解析到本服务器"
    fi
    echo "  • 示例: example.com www.example.com api.example.com"
    echo ""
    
    while true; do
        read -p "请输入域名: " DOMAINS_INPUT
        
        if [[ -z "$DOMAINS_INPUT" ]]; then
            log_error "域名不能为空，请重新输入"
            continue
        fi
        
        # 验证域名格式
        read -ra DOMAINS <<< "$DOMAINS_INPUT"
        local valid_domains=true
        
        for domain in "${DOMAINS[@]}"; do
            # 基本域名格式检查
            if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
                log_warning "域名格式可能不正确: $domain"
            fi
            
            # 检查域名解析 (适配IPv6)
            echo -n "检查域名解析: $domain ... "
            if check_domain_resolution "$domain"; then
                echo -e "${GREEN}✓${NC}"
                if [[ $NETWORK_MODE == "ipv6" ]]; then
                    log_info "$domain 的AAAA记录解析正常"
                fi
            else
                echo -e "${YELLOW}!${NC} (解析失败，但将继续)"
                if [[ $NETWORK_MODE == "ipv6" ]]; then
                    log_warning "$domain 可能缺少AAAA记录"
                fi
            fi
        done
        
        MAIN_DOMAIN=${DOMAINS[0]}
        
        echo ""
        echo -e "${GREEN}域名配置:${NC}"
        echo "  主域名: $MAIN_DOMAIN"
        echo "  所有域名: ${DOMAINS[*]}"
        echo "  域名数量: ${#DOMAINS[@]}"
        if [[ $NETWORK_MODE == "ipv6" ]]; then
            echo -e "  ${YELLOW}网络模式: 仅IPv6${NC}"
        fi
        echo ""
        
        read -p "确认域名配置正确? (Y/n): " confirm
        if [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi
        echo ""
    done
    
    log_success "域名配置完成"
}

# 证书路径配置
configure_cert_path() {
    log_step "配置证书存储路径..."
    
    echo -e "${CYAN}请选择证书安装位置:${NC}"
    echo "  1) 标准路径 (/etc/ssl/private/)"
    echo "  2) Nginx专用 (/etc/nginx/ssl/)"
    echo "  3) Apache专用 (/etc/apache2/ssl/)"
    echo "  4) 用户目录 (/home/ssl/)"
    echo "  5) 自定义路径"
    echo ""
    
    while true; do
        read -p "请选择 (1-5): " path_choice
        
        case $path_choice in
            1)
                CERT_DIR="/etc/ssl/private"
                break
                ;;
            2)
                CERT_DIR="/etc/nginx/ssl"
                break
                ;;
            3)
                CERT_DIR="/etc/apache2/ssl"
                break
                ;;
            4)
                CERT_DIR="/home/ssl"
                break
                ;;
            5)
                while true; do
                    read -p "请输入自定义路径: " custom_path
                    if [[ -n "$custom_path" ]]; then
                        CERT_DIR="$custom_path"
                        break
                    else
                        log_warning "路径不能为空，请重新输入"
                    fi
                done
                break
                ;;
            *)
                log_warning "无效选择，请输入1-5"
                continue
                ;;
        esac
    done
    
    # 创建证书目录
    if mkdir -p "$CERT_DIR" 2>/dev/null; then
        # 设置目录权限
        chmod 755 "$CERT_DIR"
        log_success "证书目录创建成功: $CERT_DIR"
    else
        log_error "无法创建证书目录: $CERT_DIR"
        exit 1
    fi
}

# 智能服务管理 - 检测并停止服务
manage_web_services() {
    local action=$1  # "stop" 或 "start"
    
    if [[ "$action" == "stop" ]]; then
        log_step "检测并管理Web服务..."
        
        # 检查80端口占用 (支持IPv6)
        local port_info=""
        if command -v ss >/dev/null 2>&1; then
            port_info=$(ss -tlnp | grep ":80 " 2>/dev/null)
        elif command -v netstat >/dev/null 2>&1; then
            port_info=$(netstat -tlnp | grep ":80 " 2>/dev/null)
        else
            log_warning "无法检查端口占用 (缺少ss/netstat命令)"
            return
        fi
        
        if [[ -n "$port_info" ]]; then
            log_warning "检测到端口80被占用"
            echo "占用信息: $port_info"
            
            # 检测常见Web服务
            local web_services=("nginx" "apache2" "httpd" "lighttpd" "caddy")
            local found_services=()
            
            for service in "${web_services[@]}"; do
                if systemctl is-active --quiet "$service" 2>/dev/null; then
                    found_services+=("$service")
                fi
            done
            
            if [[ ${#found_services[@]} -gt 0 ]]; then
                echo -e "${YELLOW}发现运行中的Web服务: ${found_services[*]}${NC}"
                read -p "是否停止这些服务以进行证书申请? (Y/n): " stop_confirm
                
                if [[ -z "$stop_confirm" || "$stop_confirm" =~ ^[Yy]$ ]]; then
                    for service in "${found_services[@]}"; do
                        log_info "停止服务: $service"
                        if systemctl stop "$service"; then
                            STOPPED_SERVICES+=("$service")
                            log_success "服务 $service 已停止"
                        else
                            log_error "停止服务 $service 失败"
                        fi
                    done
                else
                    log_warning "用户选择不停止服务，证书申请可能失败"
                fi
            else
                log_warning "端口80被占用，但未找到已知Web服务"
                echo "请手动停止占用80端口的进程，或继续尝试"
                read -p "是否继续? (Y/n): " continue_confirm
                if [[ "$continue_confirm" =~ ^[Nn]$ ]]; then
                    exit 1
                fi
            fi
        else
            log_success "端口80未被占用"
        fi
        
    elif [[ "$action" == "start" ]]; then
        # 重启之前停止的服务
        if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
            log_step "重启之前停止的Web服务..."
            
            for service in "${STOPPED_SERVICES[@]}"; do
                log_info "启动服务: $service"
                
                if systemctl start "$service"; then
                    log_success "服务 $service 启动成功"
                    
                    # 验证服务状态
                    sleep 2
                    if systemctl is-active --quiet "$service"; then
                        log_success "服务 $service 运行正常"
                    else
                        log_warning "服务 $service 状态异常"
                    fi
                else
                    log_error "服务 $service 启动失败"
                    log_info "请手动检查: systemctl status $service"
                fi
            done
            
            # 清空服务列表
            STOPPED_SERVICES=()
            log_success "Web服务重启完成"
        fi
    fi
}

# 安装系统依赖
install_dependencies() {
    log_step "安装系统依赖..."
    
    # 更新包列表
    log_info "更新系统包列表..."
    if $UPDATE_CMD >/dev/null 2>&1; then
        log_success "包列表更新完成"
    else
        log_warning "包列表更新失败，继续执行"
    fi
    
    # 根据系统安装依赖
    local packages=""
    case $OS in
        "debian")
            packages="curl wget socat cron openssl ca-certificates dnsutils"
            ;;
        "centos")
            packages="curl wget socat cronie openssl ca-certificates bind-utils"
            ;;
    esac
    
    log_info "安装必要依赖: $packages"
    if $INSTALL_CMD $packages >/dev/null 2>&1; then
        log_success "依赖安装完成"
    else
        log_warning "部分依赖安装失败，但将继续执行"
    fi
    
    # 启动cron服务
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable cron crond >/dev/null 2>&1 || true
        systemctl start cron crond >/dev/null 2>&1 || true
    fi
}

# 安装ACME.sh客户端 (支持IPv6)
install_acme_client() {
    log_step "安装ACME证书客户端..."
    
    # 检查是否已安装
    if [[ -f "/root/.acme.sh/acme.sh" ]]; then
        log_info "ACME客户端已安装，检查更新..."
        /root/.acme.sh/acme.sh --upgrade 2>&1 | tee /tmp/acme_upgrade.log || true
        log_success "ACME客户端更新完成"
    else
        log_info "下载并安装ACME客户端..."
        
        # IPv6环境特殊处理
        if [[ $NETWORK_MODE == "ipv6" ]]; then
            log_info "检测到纯IPv6环境，使用Git方式安装..."
            
            # 方法1: 使用Git克隆 (最可靠)
            if command -v git >/dev/null 2>&1; then
                log_info "尝试使用Git安装..."
                cd /root
                if git clone https://github.com/acmesh-official/acme.sh.git /tmp/acme.sh.git 2>&1 | tee /tmp/acme_install.log; then
                    cd /tmp/acme.sh.git
                    if ./acme.sh --install --nocron 2>&1 | tee -a /tmp/acme_install.log; then
                        log_success "ACME客户端安装成功 (Git方式)"
                        rm -rf /tmp/acme.sh.git
                        cd /root
                    else
                        log_error "Git安装失败"
                        cd /root
                        rm -rf /tmp/acme.sh.git
                    fi
                else
                    log_warning "Git克隆失败，尝试其他方法..."
                    cd /root
                fi
            else
                log_info "Git未安装，尝试安装Git..."
                $INSTALL_CMD git 2>&1 | tee /tmp/git_install.log
                if command -v git >/dev/null 2>&1; then
                    log_success "Git安装成功，重新尝试..."
                    cd /root
                    if git clone https://github.com/acmesh-official/acme.sh.git /tmp/acme.sh.git; then
                        cd /tmp/acme.sh.git
                        if ./acme.sh --install --nocron; then
                            log_success "ACME客户端安装成功 (Git方式)"
                            rm -rf /tmp/acme.sh.git
                            cd /root
                        fi
                    fi
                fi
            fi
            
            # 方法2: 强制使用curl/wget的IPv6模式
            if [[ ! -f "/root/.acme.sh/acme.sh" ]]; then
                log_info "尝试使用curl IPv6模式..."
                
                # 尝试curl -6
                if curl -6 -sSL https://get.acme.sh 2>/tmp/curl_error.log | sh -s 2>&1 | tee /tmp/acme_install.log; then
                    log_success "ACME客户端安装成功 (curl IPv6)"
                elif curl -sSL https://get.acme.sh 2>/tmp/curl_error.log | sh -s 2>&1 | tee /tmp/acme_install.log; then
                    log_success "ACME客户端安装成功 (curl)"
                else
                    log_warning "curl安装失败，尝试wget..."
                    cat /tmp/curl_error.log
                    
                    # 尝试wget
                    if wget -6 -O- https://get.acme.sh 2>/tmp/wget_error.log | sh -s 2>&1 | tee /tmp/acme_install.log; then
                        log_success "ACME客户端安装成功 (wget IPv6)"
                    elif wget -O- https://get.acme.sh 2>/tmp/wget_error.log | sh -s 2>&1 | tee /tmp/acme_install.log; then
                        log_success "ACME客户端安装成功 (wget)"
                    else
                        log_error "wget安装失败"
                        cat /tmp/wget_error.log
                    fi
                fi
            fi
            
        else
            # IPv4或双栈环境 - 标准安装
            log_info "使用标准安装方式..."
            
            if curl -sSL https://get.acme.sh 2>&1 | sh -s 2>&1 | tee /tmp/acme_install.log; then
                log_success "ACME客户端安装成功"
            else
                log_warning "curl安装失败，尝试wget..."
                if wget -O- https://get.acme.sh 2>&1 | sh -s 2>&1 | tee /tmp/acme_install.log; then
                    log_success "ACME客户端安装成功 (wget)"
                else
                    log_error "ACME客户端安装失败"
                    echo "安装日志已保存到: /tmp/acme_install.log"
                    cat /tmp/acme_install.log
                    exit 1
                fi
            fi
        fi
        
        # 最终检查是否安装成功
        if [[ ! -f "/root/.acme.sh/acme.sh" ]]; then
            log_error "ACME客户端安装失败，文件不存在"
            echo ""
            echo -e "${YELLOW}请尝试以下手动安装方法:${NC}"
            echo "1. 使用Git: git clone https://github.com/acmesh-official/acme.sh.git && cd acme.sh && ./acme.sh --install"
            echo "2. 检查安装日志: cat /tmp/acme_install.log"
            echo "3. 检查网络连接: ping6 github.com 或 ping6 get.acme.sh"
            exit 1
        fi
    fi
    
    # 创建软链接
    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh 2>/dev/null || true
    
    # 配置默认CA
    log_info "配置证书颁发机构 (Let's Encrypt)..."
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>&1 | tee /tmp/acme_config.log || true
    
    # 如果是IPv6环境，配置IPv6支持
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        log_info "配置IPv6支持..."
        # 设置ACME.sh使用IPv6
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        # 创建配置文件确保IPv6优先
        mkdir -p /root/.acme.sh/
        echo 'export ACME_USE_WGET=1' >> /root/.acme.sh/account.conf 2>/dev/null || true
    fi
    
    log_success "ACME客户端配置完成"
}

# 申请SSL证书 (支持IPv6)
request_ssl_certificate() {
    log_step "申请SSL证书..."
    
    # 管理Web服务 (停止)
    manage_web_services "stop"
    
    # 构建域名参数
    local domain_args=""
    for domain in "${DOMAINS[@]}"; do
        domain_args="$domain_args -d $domain"
    done
    
    log_info "开始申请证书..."
    echo -e "${YELLOW}域名: ${DOMAINS[*]}${NC}"
    echo -e "${YELLOW}使用Standalone模式，请确保80端口可访问${NC}"
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        echo -e "${CYAN}IPv6环境: 将使用IPv6进行验证${NC}"
    fi
    echo ""
    
    # 构建ACME命令参数
    local acme_cmd="/root/.acme.sh/acme.sh --issue $domain_args --standalone --force"
    
    # IPv6环境添加特殊参数
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        # 使用IPv6监听
        acme_cmd="$acme_cmd --listen-v6"
        log_info "已启用IPv6监听模式"
    fi
    
    # 申请证书
    echo "正在申请证书，请耐心等待..."
    if eval "$acme_cmd"; then
        log_success "SSL证书申请成功！"
    else
        log_error "SSL证书申请失败"
        echo -e "${YELLOW}可能的原因:${NC}"
        if [[ $NETWORK_MODE == "ipv6" ]]; then
            echo "  • 域名AAAA记录未正确解析到本服务器IPv6地址"
            echo "  • 防火墙阻止IPv6的80端口访问"
        else
            echo "  • 域名未正确解析到本服务器"
            echo "  • 防火墙阻止80端口访问"
        fi
        echo "  • Let's Encrypt服务暂时不可用"
        
        # 重启服务后退出
        manage_web_services "start"
        exit 1
    fi
}

# 安装SSL证书
install_ssl_certificate() {
    log_step "安装SSL证书到指定目录..."
    
    local key_file="$CERT_DIR/private.key"
    local cert_file="$CERT_DIR/fullchain.cer"
    local ca_file="$CERT_DIR/ca.cer"
    
    # 准备重载命令
    local reload_cmd="echo 'Certificate installed'"
    
    # 检测Web服务并设置重载命令
    if systemctl is-active --quiet nginx 2>/dev/null; then
        reload_cmd="systemctl reload nginx"
    elif systemctl is-active --quiet apache2 2>/dev/null; then
        reload_cmd="systemctl reload apache2"
    elif systemctl is-active --quiet httpd 2>/dev/null; then
        reload_cmd="systemctl reload httpd"
    fi
    
    # 安装证书
    if /root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --key-file "$key_file" \
        --fullchain-file "$cert_file" \
        --ca-file "$ca_file" \
        --reloadcmd "$reload_cmd"; then
        
        log_success "证书安装完成"
        
        # 设置安全权限
        setup_certificate_permissions "$key_file" "$cert_file" "$ca_file"
        
        log_info "证书文件位置:"
        log_info "  私钥: $key_file"
        log_info "  证书: $cert_file"
        log_info "  CA证书: $ca_file"
        
    else
        log_error "证书安装失败"
        exit 1
    fi
}

# 设置证书文件安全权限
setup_certificate_permissions() {
    local key_file=$1
    local cert_file=$2
    local ca_file=$3
    
    log_step "设置证书文件安全权限..."
    
    # 设置文件权限
    chmod 600 "$key_file" 2>/dev/null || log_warning "设置私钥权限失败"
    chmod 644 "$cert_file" 2>/dev/null || log_warning "设置证书权限失败"
    chmod 644 "$ca_file" 2>/dev/null || log_warning "设置CA证书权限失败"
    
    # 设置所有者
    chown root:root "$key_file" "$cert_file" "$ca_file" 2>/dev/null || true
    
    # 设置目录权限
    chmod 755 "$CERT_DIR" 2>/dev/null || true
    chown root:root "$CERT_DIR" 2>/dev/null || true
    
    log_success "证书权限设置完成"
}

# 设置自动续期
setup_auto_renewal() {
    log_step "设置证书自动续期..."
    
    # 检查现有的cron任务
    if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        log_info "自动续期任务已存在"
        return
    fi
    
    # 创建cron任务
    local cron_job="0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >/dev/null 2>&1"
    
    # 添加到crontab
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab - 2>/dev/null
    
    if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        log_success "自动续期任务设置完成"
        log_info "续期检查时间: 每天凌晨2点"
    else
        log_warning "自动续期任务设置失败"
        log_info "请手动添加cron任务: $cron_job"
    fi
    
    # 测试续期功能
    log_info "测试续期功能..."
    if /root/.acme.sh/acme.sh --cron --home /root/.acme.sh --force >/dev/null 2>&1; then
        log_success "续期功能测试通过"
    else
        log_warning "续期功能测试失败 (不影响正常使用)"
    fi
}

# 显示完成信息和配置指南
show_completion_info() {
    echo ""
    echo -e "${CYAN}=============================================="
    echo "           SSL证书部署完成！"
    echo "=============================================="
    echo -e "${NC}"
    
    echo -e "${GREEN}证书信息:${NC}"
    echo "  主域名: $MAIN_DOMAIN"
    echo "  所有域名: ${DOMAINS[*]}"
    echo "  证书目录: $CERT_DIR"
    echo "  私钥文件: $CERT_DIR/private.key"
    echo "  证书文件: $CERT_DIR/fullchain.cer"
    echo "  CA证书: $CERT_DIR/ca.cer"
    
    # 显示网络模式
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        echo -e "  ${CYAN}网络模式: 仅IPv6${NC}"
    elif [[ $NETWORK_MODE == "dual" ]]; then
        echo -e "  ${GREEN}网络模式: IPv4/IPv6双栈${NC}"
    else
        echo -e "  ${BLUE}网络模式: 仅IPv4${NC}"
    fi
    
    # 显示证书有效期
    if [[ -f "$CERT_DIR/fullchain.cer" ]]; then
        local expire_date=$(openssl x509 -in "$CERT_DIR/fullchain.cer" -noout -enddate 2>/dev/null | cut -d= -f2)
        if [[ -n "$expire_date" ]]; then
            echo "  有效期至: $expire_date"
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}Web服务器配置示例:${NC}"
    echo ""
    echo -e "${BLUE}Nginx 配置:${NC}"
    echo "  ssl_certificate $CERT_DIR/fullchain.cer;"
    echo "  ssl_certificate_key $CERT_DIR/private.key;"
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        echo ""
        echo -e "${CYAN}IPv6环境额外配置:${NC}"
        echo "  listen [::]:443 ssl http2;"
        echo "  # 如需同时支持IPv4和IPv6:"
        echo "  # listen 443 ssl http2;"
        echo "  # listen [::]:443 ssl http2;"
    fi
    echo ""
    echo -e "${BLUE}Apache 配置:${NC}"
    echo "  SSLCertificateFile $CERT_DIR/fullchain.cer"
    echo "  SSLCertificateKeyFile $CERT_DIR/private.key"
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        echo ""
        echo -e "${CYAN}IPv6环境额外配置:${NC}"
        echo "  <VirtualHost [::]:443>"
        echo "  # 或同时监听IPv4和IPv6:"
        echo "  # <VirtualHost *:443 [::]:443>"
    fi
    echo ""
    
    echo -e "${YELLOW}管理命令:${NC}"
    echo "  查看证书: acme.sh --list"
    echo "  手动续期: acme.sh --renew -d $MAIN_DOMAIN --force"
    echo "  删除证书: acme.sh --remove -d $MAIN_DOMAIN"
    echo ""
    
    echo -e "${GREEN}注意事项:${NC}"
    echo "  ✓ 证书已设置自动续期 (每天凌晨2点检查)"
    echo "  ✓ 请确保防火墙开放80和443端口"
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        echo "  ✓ ${CYAN}IPv6环境: 确保防火墙同时允许IPv6访问${NC}"
        echo "  ✓ ${CYAN}IPv6环境: Web服务器需配置IPv6监听${NC}"
    fi
    echo "  ✓ 重新配置Web服务器后记得重启服务"
    echo ""
    
    # 显示服务状态
    if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
        echo -e "${CYAN}Web服务状态:${NC}"
        for service in "${STOPPED_SERVICES[@]}"; do
            if systemctl is-active --quiet "$service"; then
                echo -e "  ${GREEN}✓ $service: 运行中${NC}"
            else
                echo -e "  ${RED}✗ $service: 未运行${NC}"
            fi
        done
        echo ""
    fi
    
    # IPv6特殊提示
    if [[ $NETWORK_MODE == "ipv6" ]]; then
        echo -e "${YELLOW}IPv6环境特别提示:${NC}"
        echo "  • 确保域名有正确的AAAA记录"
        echo "  • 确保Web服务器监听IPv6地址"
        echo "  • 测试命令: curl -6 https://$MAIN_DOMAIN"
        echo ""
    fi
    
    log_success "🎉 SSL证书部署完成！"
}

# 错误处理和清理
cleanup_on_error() {
    log_warning "脚本执行中断，正在清理..."
    manage_web_services "start"
    exit 1
}

# 主函数
main() {
    # 设置错误处理
    trap cleanup_on_error INT TERM
    
    # 显示横幅
    show_banner
    
    # 执行检查和配置步骤
    check_root
    detect_network_type  # 新增: 检测网络类型
    check_network
    detect_os
    
    # 交互式配置
    configure_domains
    configure_cert_path
    
    echo -e "${PURPLE}开始执行SSL证书部署流程...${NC}"
    echo ""
    
    # 执行部署步骤
    install_dependencies
    install_acme_client
    request_ssl_certificate
    install_ssl_certificate
    setup_auto_renewal
    
    # 重启Web服务
    manage_web_services "start"
    
    # 显示完成信息
    show_completion_info
}

# 启动主函数
main "$@"
