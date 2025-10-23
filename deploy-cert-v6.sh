# 检查网络连接 (IPv4/IPv6兼容)
check_network() {
    log_step "检查网络连接..."
    
    local ipv4_ok=false
    local ipv6_ok=false
    
    # 检查IPv4
    local test_hosts_v4=("8.8.8.8" "1.1.1.1")
    for host in "${test_hosts_v4[@]}"; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
            ipv4_ok=true
            break
        fi
    done
    
    # 检查IPv6
    local test_hosts_v6=("2001:4860:4860::8888" "2606:4700:4700::1111")
    for host in "${test_hosts_v6[@]}"; do
        if ping6 -c 1 -W 3 "$host" >/dev/null 2>&1; then
            ipv6_ok=true
            break
        fi
    done
    
    # 判断网络状态
    if [[ $ipv4_ok == true && $ipv6_ok == true ]]; then
        log_success "网络连接正常 (IPv4 + IPv6 双栈)"
        NETWORK_TYPE="dual"
    elif [[ $ipv4_ok == true ]]; then
        log_success "网络连接正常 (仅IPv4)"
        NETWORK_TYPE="ipv4"
    elif [[ $ipv6_ok == true ]]; then
        log_success "网络连接正常 (仅IPv6)"
        NETWORK_TYPE="ipv6"
        log_warning "检测到仅IPv6环境,某些功能可能受限"
    else
        log_error "网络连接失败,请检查网络配置"
        exit 1
    fi
    
    # 检查域名解析
    if ! host google.com >/dev/null 2>&1; then
        log_warning "DNS解析可能存在问题"
    fi
}

# 检查域名解析 (支持IPv6)
check_domain_dns() {
    local domain=$1
    local has_a=false
    local has_aaaa=false
    
    # 检查A记录 (IPv4)
    if dig +short A "$domain" 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        has_a=true
    fi
    
    # 检查AAAA记录 (IPv6)
    if dig +short AAAA "$domain" 2>/dev/null | grep -qE '^[0-9a-fA-F:]+$'; then
        has_aaaa=true
    fi
    
    if [[ "$NETWORK_TYPE" == "ipv6" ]]; then
        if [[ $has_aaaa == true ]]; then
            echo -e "${GREEN}✓${NC} (IPv6解析正常)"
            return 0
        else
            echo -e "${RED}✗${NC} (缺少AAAA记录)"
            return 1
        fi
    elif [[ "$NETWORK_TYPE" == "ipv4" ]]; then
        if [[ $has_a == true ]]; then
            echo -e "${GREEN}✓${NC} (IPv4解析正常)"
            return 0
        else
            echo -e "${RED}✗${NC} (缺少A记录)"
            return 1
        fi
    else
        if [[ $has_a == true || $has_aaaa == true ]]; then
            echo -e "${GREEN}✓${NC}"
            return 0
        else
            echo -e "${RED}✗${NC}"
            return 1
        fi
    fi
}

# ACME申请证书 (IPv6支持)
request_ssl_certificate() {
    log_step "申请SSL证书..."
    
    manage_web_services "stop"
    
    local domain_args=""
    for domain in "${DOMAINS[@]}"; do
        domain_args="$domain_args -d $domain"
    done
    
    # 根据网络类型选择参数
    local listen_args=""
    if [[ "$NETWORK_TYPE" == "ipv6" ]]; then
        listen_args="--listen-v6"
        log_info "使用IPv6模式申请证书"
    fi
    
    log_info "开始申请证书..."
    echo -e "${YELLOW}域名: ${DOMAINS[*]}${NC}"
    
    if /root/.acme.sh/acme.sh --issue $domain_args --standalone $listen_args --force; then
        log_success "SSL证书申请成功！"
    else
        log_error "SSL证书申请失败"
        echo -e "${YELLOW}仅IPv6环境常见问题:${NC}"
        echo "  • 确保域名有AAAA记录指向本服务器"
        echo "  • 确保防火墙允许IPv6的80端口"
        echo "  • Let's Encrypt服务器需要支持IPv6访问"
        manage_web_services "start"
        exit 1
    fi
}
