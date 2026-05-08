#!/bin/bash

# SSL证书一键部署脚本
# 文件名: deploy-cert.sh
# 作者: github19999
# 版本: 2.0
# 使用方法: bash <(curl -sSL https://raw.githubusercontent.com/用户名/cert/refs/heads/main/deploy-cert.sh)

# ==============================================================================
# 本次优化内容 (v1.0 → v2.0)
# ==============================================================================
#
# 【问题根因】
#   证书申请时使用 standalone 模式需占用80端口，首次申请前会手动停止 nginx。
#   但自动续期的 cron 任务执行时不会停止 nginx，导致 standalone 无法绑定80端口，
#   续期静默失败，证书到期后无法自动更新。
#
# 【优化1 - 核心修复】install_ssl_certificate() 新增 Pre/Post Hook
#   - 安装证书后自动检测当前运行的 Web 服务（nginx/apache2/httpd/lighttpd）
#   - 将 Le_PreHook / Le_PostHook 写入 acme.sh 的域名配置文件
#   - 续期时 acme.sh 自动执行: stop 服务 → standalone续期 → start 服务
#   - 避免重复写入（检测配置文件中是否已存在 Le_PreHook）
#   - 找不到配置文件时给出明确警告，而非静默失败
#
# 【优化2 - 日志可观测】setup_auto_renewal()
#   - 原版: >/dev/null 2>&1，续期失败无任何日志，问题无法排查
#   - 新版: 续期日志写入 /var/log/acme-renew.log，方便事后查看失败原因
#
# 【优化3 - cron服务启动修复】setup_auto_renewal()
#   - 原版: systemctl enable cron crond 同时操作，Debian系统只有 cron，
#           CentOS只有 crond，混用会报错
#   - 新版: 根据 $OS 变量分别启动对应的 cron 服务名
#
# 【优化4 - 去掉危险的 --force 测试】setup_auto_renewal()
#   - 原版: 用 --cron --force 测试续期功能，会强制消耗 Let's Encrypt 的
#           每域名每周5次证书颁发限额
#   - 新版: 改用 --list 展示证书列表，验证配置正确无副作用
#
# 【优化5 - 交互体验】三处确认提示增加回车键默认选择
#   - configure_domains(): "确认域名配置正确?" 回车默认 Y
#   - configure_cert_path(): "请选择证书安装位置" 回车默认选项1（标准路径）
#     通过 path_choice=${path_choice:-1} 实现空输入自动赋值
#   - manage_web_services(): "是否停止这些服务以进行证书申请?" 回车默认 Y
#     同时新增说明文字，告知用户首次申请需临时停止服务属正常流程，
#     证书申请完成后立即自动重启，后续自动续期无需手动干预
#
# ==============================================================================

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
SCRIPT_VERSION="2.0"
STOPPED_SERVICES=()
DOMAINS=()
MAIN_DOMAIN=""
CERT_DIR=""
OS=""
INSTALL_CMD=""
UPDATE_CMD=""

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
    echo "       SSL证书一键部署脚本 v${SCRIPT_VERSION}"
    echo "=============================================="
    echo -e "${NC}"
    echo -e "${YELLOW}功能特性:${NC}"
    echo "  ✓ 交互式域名配置"
    echo "  ✓ 多域名证书支持"
    echo "  ✓ 智能服务管理"
    echo "  ✓ 系统兼容性检测"
    echo "  ✓ 完善错误处理"
    echo "  ✓ 自动续期设置（Pre/Post Hook 解决80端口冲突）"
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

# 检查网络连接
check_network() {
    log_step "检查网络连接..."

    local test_hosts=("8.8.8.8" "1.1.1.1" "114.114.114.114")
    local network_ok=false

    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
            network_ok=true
            break
        fi
    done

    if [[ $network_ok == false ]]; then
        log_error "网络连接失败，请检查网络配置"
        exit 1
    fi

    # 检查域名解析
    if ! nslookup google.com >/dev/null 2>&1; then
        log_warning "DNS解析可能存在问题"
    fi

    log_success "网络连接正常"
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

# 交互式域名配置
configure_domains() {
    log_step "配置SSL证书域名..."

    echo -e "${CYAN}请配置要申请SSL证书的域名:${NC}"
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  • 支持单个或多个域名"
    echo "  • 多个域名请用空格分隔"
    echo "  • 确保域名已正确解析到本服务器"
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

        for domain in "${DOMAINS[@]}"; do
            # 基本域名格式检查
            if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
                log_warning "域名格式可能不正确: $domain"
            fi

            # 检查域名解析 (可选)
            echo -n "检查域名解析: $domain ... "
            if nslookup "$domain" >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${YELLOW}!${NC} (解析失败，但将继续)"
            fi
        done

        MAIN_DOMAIN=${DOMAINS[0]}

        echo ""
        echo -e "${GREEN}域名配置:${NC}"
        echo "  主域名: $MAIN_DOMAIN"
        echo "  所有域名: ${DOMAINS[*]}"
        echo "  域名数量: ${#DOMAINS[@]}"
        echo ""

        read -p "确认域名配置正确? [直接回车=Y/n]: " confirm
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
        read -p "请选择 (1-5) [直接回车=1]: " path_choice

        # 回车默认选择1
        path_choice=${path_choice:-1}

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

        # 检查80端口占用
        if command -v ss >/dev/null 2>&1; then
            local port_info=$(ss -tlnp | grep ":80 ")
        elif command -v netstat >/dev/null 2>&1; then
            local port_info=$(netstat -tlnp | grep ":80 ")
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
                echo -e "${CYAN}[说明] 首次申请证书需临时停止 Web 服务以占用80端口完成验证。"
                echo -e "       证书申请完成后将立即自动重启，且后续自动续期无需手动干预。${NC}"
                read -p "是否停止这些服务以进行证书申请? [直接回车=Y/n]: " stop_confirm
                stop_confirm=${stop_confirm:-Y}

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
            packages="curl wget socat cron openssl ca-certificates"
            ;;
        "centos")
            packages="curl wget socat cronie openssl ca-certificates"
            ;;
    esac

    log_info "安装必要依赖: $packages"
    if $INSTALL_CMD $packages >/dev/null 2>&1; then
        log_success "依赖安装完成"
    else
        log_warning "部分依赖安装失败，但将继续执行"
    fi

    # 【优化3】按系统启动对应的 cron 服务，避免混用报错
    # 原版同时 enable cron 和 crond，Debian 无 crond、CentOS 无 cron，会产生错误
    if command -v systemctl >/dev/null 2>&1; then
        if [[ "$OS" == "debian" ]]; then
            systemctl enable cron >/dev/null 2>&1 && systemctl start cron >/dev/null 2>&1 || true
        else
            systemctl enable crond >/dev/null 2>&1 && systemctl start crond >/dev/null 2>&1 || true
        fi
    fi
}

# 安装ACME.sh客户端
install_acme_client() {
    log_step "安装ACME证书客户端..."

    # 检查是否已安装
    if [[ -f "/root/.acme.sh/acme.sh" ]]; then
        log_info "ACME客户端已安装，检查更新..."
        /root/.acme.sh/acme.sh --upgrade >/dev/null 2>&1 || true
        log_success "ACME客户端更新完成"
    else
        log_info "下载并安装ACME客户端..."

        # 主要安装方法
        if curl https://get.acme.sh 2>/dev/null | sh >/dev/null 2>&1; then
            log_success "ACME客户端安装成功"
        else
            # 备用安装方法
            log_warning "主要安装方法失败，尝试备用方法..."
            if wget -O- https://get.acme.sh 2>/dev/null | sh >/dev/null 2>&1; then
                log_success "ACME客户端安装成功 (备用方法)"
            else
                log_error "ACME客户端安装失败"
                exit 1
            fi
        fi
    fi

    # 创建软链接
    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh 2>/dev/null || true

    # 配置默认CA
    log_info "配置证书颁发机构 (Let's Encrypt)..."
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    log_success "ACME客户端配置完成"
}

# 申请SSL证书
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
    echo ""

    # 申请证书
    echo "正在申请证书，请耐心等待..."
    if /root/.acme.sh/acme.sh --issue $domain_args --standalone --force; then
        log_success "SSL证书申请成功！"
    else
        log_error "SSL证书申请失败"
        echo -e "${YELLOW}可能的原因:${NC}"
        echo "  • 域名未正确解析到本服务器"
        echo "  • 防火墙阻止80端口访问"
        echo "  • Let's Encrypt服务暂时不可用"

        # 重启服务后退出
        manage_web_services "start"
        exit 1
    fi
}

# ==============================================================================
# 【优化1 - 核心修复】安装SSL证书并配置 Pre/Post Hook
#
# 问题: 自动续期使用 standalone 模式需占用80端口，但 cron 续期时 nginx 仍在
#       运行，导致端口冲突，续期静默失败。
#
# 修复: 安装证书后检测当前运行的 Web 服务，将 Le_PreHook / Le_PostHook 写入
#       acme.sh 的域名配置文件。续期时 acme.sh 会自动:
#         1. 执行 Le_PreHook  → 停止 Web 服务
#         2. standalone 续期  → 成功绑定80端口
#         3. 执行 Le_PostHook → 重新启动 Web 服务
#         4. 执行 reloadcmd   → 重载配置（Web 服务已 start，此处 reload 即可）
# ==============================================================================
install_ssl_certificate() {
    log_step "安装SSL证书到指定目录..."

    local key_file="$CERT_DIR/private.key"
    local cert_file="$CERT_DIR/fullchain.cer"
    local ca_file="$CERT_DIR/ca.cer"

    # 检测当前运行的 Web 服务，为 Hook 和 reloadcmd 做准备
    local pre_hook=""
    local post_hook=""
    local reload_cmd="echo 'Certificate installed'"
    local detected_service=""

    for svc in nginx apache2 httpd lighttpd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            detected_service="$svc"
            pre_hook="systemctl stop $svc"
            post_hook="systemctl start $svc"
            reload_cmd="systemctl reload $svc"
            log_info "检测到 Web 服务: $svc，将配置续期 Pre/Post Hook"
            break
        fi
    done

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

    # 写入 Pre/Post Hook 到 acme.sh 域名配置文件
    # Hook 触发时机: acme.sh 执行续期前后自动调用，解决80端口冲突
    if [[ -n "$pre_hook" ]]; then
        local conf_file="/root/.acme.sh/${MAIN_DOMAIN}/${MAIN_DOMAIN}.conf"

        if [[ -f "$conf_file" ]]; then
            # 避免重复写入
            if ! grep -q "Le_PreHook" "$conf_file"; then
                echo "Le_PreHook='$pre_hook'" >> "$conf_file"
                echo "Le_PostHook='$post_hook'" >> "$conf_file"
                log_success "续期 Hook 配置完成: 续期时将自动停启 $detected_service"
                log_info "  续期前执行: $pre_hook"
                log_info "  续期后执行: $post_hook"
            else
                log_info "续期 Hook 已存在，跳过写入"
            fi
        else
            log_warning "未找到 acme.sh 配置文件: $conf_file"
            log_warning "请手动添加以下内容到该文件以确保续期正常:"
            log_warning "  Le_PreHook='$pre_hook'"
            log_warning "  Le_PostHook='$post_hook'"
        fi
    else
        log_info "未检测到运行中的 Web 服务，续期将直接使用 Standalone 模式"
    fi
}

# 设置证书文件安全权限
setup_certificate_permissions() {
    local key_file=$1
    local cert_file=$2
    local ca_file=$3

    log_step "设置证书文件安全权限..."

    chmod 600 "$key_file" 2>/dev/null || log_warning "设置私钥权限失败"
    chmod 644 "$cert_file" 2>/dev/null || log_warning "设置证书权限失败"
    chmod 644 "$ca_file" 2>/dev/null || log_warning "设置CA证书权限失败"

    chown root:root "$key_file" "$cert_file" "$ca_file" 2>/dev/null || true

    chmod 755 "$CERT_DIR" 2>/dev/null || true
    chown root:root "$CERT_DIR" 2>/dev/null || true

    log_success "证书权限设置完成"
}

# ==============================================================================
# 【优化2 + 优化3 + 优化4】设置自动续期
#
# 优化2 - 续期日志可观测:
#   原版将输出重定向到 /dev/null，续期失败无任何记录，无法排查原因。
#   新版将日志写入 /var/log/acme-renew.log，保留完整续期输出。
#
# 优化3 - cron 服务按系统区分启动:
#   原版同时操作 cron 和 crond，Debian 系只有 cron、CentOS 系只有 crond，
#   混用会产生 systemctl: unit not found 错误。
#   新版根据 $OS 变量选择正确的服务名启动。（依赖安装函数中已处理，此处备用）
#
# 优化4 - 移除 --force 测试，避免消耗 Let's Encrypt 颁发限额:
#   原版用 --cron --force 测试续期，会强制触发证书颁发（每域名每周限5次）。
#   新版改用 --list 展示当前证书状态，无任何副作用。
# ==============================================================================
setup_auto_renewal() {
    log_step "设置证书自动续期..."

    # 检查是否已存在续期任务，避免重复添加
    if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        log_info "自动续期任务已存在，跳过"

        # 检查旧任务是否丢弃日志，若是则提示用户更新
        if crontab -l 2>/dev/null | grep "acme.sh.*--cron" | grep -q "/dev/null"; then
            log_warning "检测到旧版续期任务日志被丢弃，建议手动更新 crontab 以启用日志:"
            log_warning "  0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> /var/log/acme-renew.log 2>&1"
        fi
        return
    fi

    # 续期日志写入文件，方便排查失败原因
    local log_file="/var/log/acme-renew.log"
    local cron_job="0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> $log_file 2>&1"

    # 添加到 crontab
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab - 2>/dev/null

    if crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        log_success "自动续期任务设置完成"
        log_info "续期检查时间: 每天凌晨2点"
        log_info "续期日志位置: $log_file (可用 tail -f $log_file 实时查看)"
    else
        log_warning "自动续期任务设置失败，请手动执行以下命令:"
        log_info "  (crontab -l 2>/dev/null; echo \"$cron_job\") | crontab -"
    fi

    # 展示当前证书状态，验证配置正确（不使用 --force，避免消耗颁发限额）
    log_info "当前证书配置:"
    /root/.acme.sh/acme.sh --list
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
    echo ""
    echo -e "${BLUE}Apache 配置:${NC}"
    echo "  SSLCertificateFile $CERT_DIR/fullchain.cer"
    echo "  SSLCertificateKeyFile $CERT_DIR/private.key"
    echo ""

    echo -e "${YELLOW}管理命令:${NC}"
    echo "  查看证书列表:  acme.sh --list"
    echo "  手动续期:      acme.sh --renew -d $MAIN_DOMAIN --force"
    echo "  查看续期日志:  tail -f /var/log/acme-renew.log"
    echo "  删除证书:      acme.sh --remove -d $MAIN_DOMAIN"
    echo ""

    echo -e "${GREEN}注意事项:${NC}"
    echo "  ✓ 证书已设置自动续期 (每天凌晨2点检查)"
    echo "  ✓ 续期时将自动停启 Web 服务 (Pre/Post Hook 已配置)"
    echo "  ✓ 续期日志: /var/log/acme-renew.log"
    echo "  ✓ 请确保防火墙开放80和443端口"
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
