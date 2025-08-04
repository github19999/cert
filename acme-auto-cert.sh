#!/bin/bash

# ACME证书自动申请安装脚本
# 作者: Auto Generated
# 版本: 1.0

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

# 检查操作系统
check_os() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
        INSTALL_CMD="apt install -y"
        UPDATE_CMD="apt update"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
        INSTALL_CMD="yum install -y"
        UPDATE_CMD="yum update -y"
    else
        log_error "不支持的操作系统"
        exit 1
    fi
    log_info "检测到操作系统: $OS"
}

# 获取用户输入的域名
get_domains() {
    echo -e "${BLUE}请输入要申请证书的域名信息:${NC}"
    echo "支持多域名，用空格分隔 (例如: example.com www.example.com)"
    read -p "域名: " DOMAINS_INPUT
    
    if [[ -z "$DOMAINS_INPUT" ]]; then
        log_error "域名不能为空"
        exit 1
    fi
    
    # 转换为数组
    read -ra DOMAINS <<< "$DOMAINS_INPUT"
    MAIN_DOMAIN=${DOMAINS[0]}
    
    log_info "主域名: $MAIN_DOMAIN"
    log_info "所有域名: ${DOMAINS[*]}"
}

# 设置证书存储路径
set_cert_paths() {
    echo -e "${BLUE}请选择证书安装位置:${NC}"
    echo "1) 默认路径 (/etc/ssl/private/)"
    echo "2) 自定义路径"
    read -p "请选择 (1-2): " path_choice
    
    case $path_choice in
        1)
            CERT_DIR="/etc/ssl/private"
            ;;
        2)
            read -p "请输入证书存储目录: " CERT_DIR
            ;;
        *)
            log_warning "使用默认路径"
            CERT_DIR="/etc/ssl/private"
            ;;
    esac
    
    # 创建证书目录
    mkdir -p "$CERT_DIR"
    log_info "证书将安装到: $CERT_DIR"
}

# 检查端口占用并停止相关服务
check_port() {
    local port=$1
    log_info "检查端口 $port 占用情况..."
    
    if ss -tlnp | grep ":$port " > /dev/null; then
        log_warning "端口 $port 被占用，正在识别占用服务..."
        
        # 获取占用端口的进程信息
        local pid_info=$(ss -tlnp | grep ":$port " | head -1)
        log_info "端口占用信息: $pid_info"
        
        # 尝试停止常见的Web服务
        local services_to_check=("nginx" "apache2" "httpd" "lighttpd" "caddy")
        local found_service=false
        
        for service in "${services_to_check[@]}"; do
            if systemctl is-active --quiet $service 2>/dev/null; then
                log_warning "发现运行中的服务: $service"
                log_info "停止服务: $service"
                
                if systemctl stop $service; then
                    STOPPED_SERVICES+=($service)
                    log_success "服务 $service 已停止"
                    found_service=true
                else
                    log_error "停止服务 $service 失败"
                fi
            fi
        done
        
        # 再次检查端口是否被释放
        sleep 2
        if ss -tlnp | grep ":$port " > /dev/null; then
            if [[ $found_service == false ]]; then
                log_error "端口 $port 仍被占用，且未找到已知的Web服务"
                log_info "请手动停止占用端口的进程，或使用其他端口进行验证"
                
                # 提供手动处理选项
                echo -e "${YELLOW}选项:${NC}"
                echo "1) 继续执行（可能失败）"
                echo "2) 退出脚本，手动处理"
                read -p "请选择 (1-2): " choice
                
                case $choice in
                    1)
                        log_warning "继续执行，如果失败请手动停止占用进程"
                        ;;
                    2)
                        log_info "退出脚本，请手动停止占用端口的进程后重新运行"
                        exit 1
                        ;;
                    *)
                        log_warning "默认继续执行"
                        ;;
                esac
            else
                log_warning "端口可能仍被其他进程占用"
            fi
        else
            log_success "端口 $port 已释放"
        fi
    else
        log_success "端口 $port 未被占用"
    fi
}

# 安装依赖
install_dependencies() {
    log_info "更新系统包列表..."
    $UPDATE_CMD > /dev/null 2>&1
    
    log_info "安装必要依赖..."
    $INSTALL_CMD socat cron curl wget > /dev/null 2>&1
    
    log_success "依赖安装完成"
}

# 安装acme.sh
install_acme() {
    if [[ -f "/root/.acme.sh/acme.sh" ]]; then
        log_info "acme.sh已安装，检查更新..."
        /root/.acme.sh/acme.sh --upgrade > /dev/null 2>&1 || true
    else
        log_info "下载并安装acme.sh..."
        curl -s https://get.acme.sh | sh > /dev/null 2>&1
    fi
    
    # 创建软链接
    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
    
    # 设置默认CA为Let's Encrypt
    log_info "设置默认CA为Let's Encrypt..."
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt > /dev/null 2>&1
    
    log_success "acme.sh安装完成"
}

# 申请证书
request_certificate() {
    log_info "申请SSL证书..."
    
    # 检查80端口占用
    STOPPED_SERVICES=()
    check_port 80
    
    # 构建域名参数
    local domain_args=""
    for domain in "${DOMAINS[@]}"; do
        domain_args="$domain_args -d $domain"
    done
    
    # 申请证书
    if /root/.acme.sh/acme.sh --issue $domain_args --standalone --force; then
        log_success "证书申请成功"
    else
        log_error "证书申请失败"
        restart_services
        exit 1
    fi
}

# 安装证书
install_certificate() {
    log_info "安装SSL证书到指定目录..."
    
    local key_file="$CERT_DIR/private.key"
    local cert_file="$CERT_DIR/fullchain.cer"
    
    if /root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --key-file "$key_file" \
        --fullchain-file "$cert_file" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true"; then
        
        # 设置证书文件权限
        chmod 600 "$key_file"
        chmod 644 "$cert_file"
        
        log_success "证书安装完成"
        log_info "私钥文件: $key_file"
        log_info "证书文件: $cert_file"
    else
        log_error "证书安装失败"
        exit 1
    fi
}

# 重启之前停止的服务
restart_services() {
    if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
        log_info "重启之前停止的服务..."
        for service in "${STOPPED_SERVICES[@]}"; do
            log_info "正在启动服务: $service"
            
            # 检查服务是否存在且可启动
            if systemctl is-enabled --quiet $service 2>/dev/null || systemctl is-active --quiet $service 2>/dev/null; then
                if systemctl start $service; then
                    log_success "服务 $service 启动成功"
                    
                    # 验证服务是否真正运行
                    sleep 2
                    if systemctl is-active --quiet $service; then
                        log_success "服务 $service 运行状态正常"
                    else
                        log_warning "服务 $service 启动后状态异常"
                    fi
                else
                    log_error "服务 $service 启动失败"
                    log_info "请手动检查服务状态: systemctl status $service"
                fi
            else
                log_warning "服务 $service 不存在或已禁用，跳过启动"
            fi
        done
        
        # 清空已停止服务列表
        STOPPED_SERVICES=()
        log_success "服务重启流程完成"
    else
        log_info "没有需要重启的服务"
    fi
}

# 设置自动续期
setup_auto_renewal() {
    log_info "设置证书自动续期..."
    
    # 检查crontab是否已存在acme任务
    if ! crontab -l 2>/dev/null | grep -q "acme.sh"; then
        # 添加到crontab (每天凌晨2点检查续期)
        (crontab -l 2>/dev/null; echo "0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null 2>&1") | crontab -
        log_success "自动续期设置完成"
    else
        log_info "自动续期任务已存在"
    fi
}

# 显示服务状态
show_service_status() {
    if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
        echo -e "${BLUE}===== 服务状态 =====${NC}"
        for service in "${STOPPED_SERVICES[@]}"; do
            if systemctl is-active --quiet $service; then
                echo -e "${GREEN}✓ $service: 运行中${NC}"
            else
                echo -e "${RED}✗ $service: 未运行${NC}"
                echo -e "${YELLOW}  手动启动: systemctl start $service${NC}"
            fi
        done
        echo ""
    fi
}
# 显示证书信息
show_certificate_info() {
    show_service_status
    
    log_success "===== 证书信息 ====="
    echo -e "${GREEN}主域名:${NC} $MAIN_DOMAIN"
    echo -e "${GREEN}所有域名:${NC} ${DOMAINS[*]}"
    echo -e "${GREEN}证书目录:${NC} $CERT_DIR"
    echo -e "${GREEN}私钥文件:${NC} $CERT_DIR/private.key"
    echo -e "${GREEN}证书文件:${NC} $CERT_DIR/fullchain.cer"
    
    # 显示证书到期时间
    if [[ -f "$CERT_DIR/fullchain.cer" ]]; then
        local expire_date=$(openssl x509 -in "$CERT_DIR/fullchain.cer" -noout -enddate | cut -d= -f2)
        echo -e "${GREEN}到期时间:${NC} $expire_date"
    fi
    
    echo -e "${YELLOW}注意事项:${NC}"
    echo "1. 证书已设置自动续期"
    echo "2. 请确保防火墙开放80和443端口"
    echo "3. 如需手动续期: acme.sh --renew -d $MAIN_DOMAIN --force"
}

# 清理函数
cleanup() {
    restart_services
}

# 主函数
main() {
    echo -e "${BLUE}"
    echo "=================================="
    echo "    ACME SSL证书自动申请脚本"
    echo "=================================="
    echo -e "${NC}"
    
    # 设置退出时清理
    trap cleanup EXIT
    
    check_root
    check_os
    get_domains
    set_cert_paths
    
    install_dependencies
    install_acme
    request_certificate
    install_certificate
    setup_auto_renewal
    
    restart_services
    show_certificate_info
    
    log_success "脚本执行完成！"
}

# 运行主函数
main "$@"
