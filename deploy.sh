#!/bin/bash

# SSL证书一键部署脚本
# 版本: 1.0
# 用途: 下载并执行ACME SSL证书自动申请脚本

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置信息
GITHUB_USER="github19999"  # 替换为你的GitHub用户名
REPO_NAME="zsan"      # 替换为你的仓库名
SCRIPT_NAME="acme-auto-cert.sh"
SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/main/${SCRIPT_NAME}"

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

# 检查网络连接
check_network() {
    log_info "检查网络连接..."
    if ! ping -c 1 github.com > /dev/null 2>&1; then
        log_error "无法连接到GitHub，请检查网络连接"
        exit 1
    fi
    log_success "网络连接正常"
}

# 检查必要工具
check_tools() {
    log_info "检查必要工具..."
    
    # 检查wget
    if ! command -v wget > /dev/null 2>&1; then
        log_warning "wget未安装，正在安装..."
        if command -v apt > /dev/null 2>&1; then
            apt update > /dev/null 2>&1
            apt install -y wget > /dev/null 2>&1
        elif command -v yum > /dev/null 2>&1; then
            yum install -y wget > /dev/null 2>&1
        else
            log_error "无法安装wget，请手动安装"
            exit 1
        fi
        log_success "wget安装完成"
    fi
    
    log_success "工具检查完成"
}

# 清理旧文件
cleanup_old_files() {
    if [[ -f "$SCRIPT_NAME" ]]; then
        log_info "清理旧的脚本文件..."
        rm -f "$SCRIPT_NAME"
    fi
}

# 下载脚本
download_script() {
    log_info "从GitHub下载SSL证书申请脚本..."
    log_info "下载地址: $SCRIPT_URL"
    
    if wget -q --timeout=30 "$SCRIPT_URL" -O "$SCRIPT_NAME"; then
        log_success "脚本下载成功"
    else
        log_error "脚本下载失败"
        log_info "请检查以下内容："
        log_info "1. GitHub用户名和仓库名是否正确"
        log_info "2. 脚本文件名是否正确"
        log_info "3. 网络连接是否正常"
        exit 1
    fi
}

# 验证脚本
verify_script() {
    log_info "验证下载的脚本..."
    
    # 检查文件是否存在且不为空
    if [[ ! -f "$SCRIPT_NAME" ]] || [[ ! -s "$SCRIPT_NAME" ]]; then
        log_error "脚本文件无效或为空"
        exit 1
    fi
    
    # 检查是否为bash脚本
    if ! head -1 "$SCRIPT_NAME" | grep -q "#!/bin/bash"; then
        log_error "下载的文件不是有效的Bash脚本"
        exit 1
    fi
    
    log_success "脚本验证通过"
}

# 设置执行权限
set_permissions() {
    log_info "设置脚本执行权限..."
    chmod +x "$SCRIPT_NAME"
    log_success "权限设置完成"
}

# 显示脚本信息
show_script_info() {
    echo -e "${BLUE}"
    echo "=================================="
    echo "     SSL证书一键部署工具"
    echo "=================================="
    echo -e "${NC}"
    echo -e "${GREEN}脚本来源:${NC} $SCRIPT_URL"
    echo -e "${GREEN}本地文件:${NC} $(pwd)/$SCRIPT_NAME"
    echo -e "${GREEN}文件大小:${NC} $(du -h "$SCRIPT_NAME" | cut -f1)"
    echo ""
}

# 执行主脚本
run_main_script() {
    log_info "开始执行SSL证书申请脚本..."
    echo -e "${YELLOW}注意: 请按照提示输入域名和选择证书路径${NC}"
    echo ""
    
    # 运行主脚本
    if ./"$SCRIPT_NAME"; then
        log_success "SSL证书申请脚本执行完成！"
    else
        log_error "SSL证书申请脚本执行失败"
        log_info "你可以手动运行: sudo ./$SCRIPT_NAME"
        exit 1
    fi
}

# 清理函数
cleanup() {
    log_info "清理临时文件..."
    # 可选择是否保留脚本文件
    read -p "是否删除下载的脚本文件? (y/N): " delete_script
    if [[ "$delete_script" =~ ^[Yy]$ ]]; then
        rm -f "$SCRIPT_NAME"
        log_success "脚本文件已删除"
    else
        log_info "脚本文件保留为: $(pwd)/$SCRIPT_NAME"
    fi
}

# 主函数
main() {
    show_script_info
    
    check_root
    check_network
    check_tools
    cleanup_old_files
    download_script
    verify_script
    set_permissions
    
    echo -e "${GREEN}准备工作完成！即将启动SSL证书申请程序...${NC}"
    echo ""
    
    run_main_script
    
    echo ""
    cleanup
    
    log_success "部署完成！"
}

# 错误处理
trap 'log_error "脚本执行被中断"; exit 1' INT TERM

# 运行主函数
main "$@"
