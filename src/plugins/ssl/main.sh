#!/bin/bash

# DataOnline N8N Manager - SSL Automation Plugin
# Phiên bản: 1.0.0

set -euo pipefail

# Source core modules
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_PROJECT_ROOT="$(dirname "$(dirname "$PLUGIN_DIR")")"

[[ -z "${LOGGER_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/logger.sh"
[[ -z "${CONFIG_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/config.sh"
[[ -z "${UTILS_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/utils.sh"
[[ -z "${UI_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/ui.sh"
[[ -z "${SPINNER_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/spinner.sh"

# Constants
readonly SSL_LOADED=true
readonly WEBROOT_PATH="/var/www/html"
readonly CERTBOT_LOG="/var/log/letsencrypt"

# ===== DNS VALIDATION =====

validate_domain_dns() {
    local domain="$1"
    local server_ip=$(get_public_ip)

    ui_start_spinner "Kiểm tra DNS cho $domain"

    local resolved_ip=$(dig +short A "$domain" @1.1.1.1 | tail -n1)

    ui_stop_spinner

    if [[ -z "$resolved_ip" ]]; then
        ui_status "error" "Không thể phân giải DNS cho $domain"
        echo -n -e "${UI_YELLOW}Bỏ qua kiểm tra DNS? [y/N]: ${UI_NC}"
        read -r skip_dns
        return $([[ "$skip_dns" =~ ^[Yy]$ ]] && echo 0 || echo 1)
    fi

    if [[ "$resolved_ip" == "$server_ip" ]]; then
        ui_status "success" "DNS đã trỏ đúng: $domain → $server_ip"
        return 0
    else
        ui_status "error" "DNS không trỏ đúng: $domain → $resolved_ip (cần: $server_ip)"
        echo -n -e "${UI_YELLOW}Bỏ qua kiểm tra DNS? [y/N]: ${UI_NC}"
        read -r skip_dns
        return $([[ "$skip_dns" =~ ^[Yy]$ ]] && echo 0 || echo 1)
    fi
}

# ===== NGINX CONFIGURATION =====

create_nginx_ssl_config() {
    local domain="$1"
    local n8n_port="${2:-5678}"
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"

    ui_section "Tạo cấu hình Nginx SSL"

    # Step 1: Create webroot directory
    if ! ui_run_command "Tạo webroot directory" "
        mkdir -p $WEBROOT_PATH/.well-known/acme-challenge
        chown www-data:www-data $WEBROOT_PATH -R
        chmod 755 $WEBROOT_PATH -R
    "; then
        return 1
    fi

    # Step 2: Create nginx config file
    ui_start_spinner "Tạo file cấu hình Nginx"

    cat >"$nginx_conf" <<EOF
server {
    listen 80;
    server_name $domain;

    location /.well-known/acme-challenge/ {
        root $WEBROOT_PATH;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 100M;
    
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    access_log /var/log/nginx/$domain.access.log;
    error_log /var/log/nginx/$domain.error.log;

    location / {
        proxy_pass http://127.0.0.1:$n8n_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 7200s;
        proxy_send_timeout 7200s;
    }

    location ~ /\\. {
        deny all;
    }
}
EOF

    ui_stop_spinner

    # Step 3: Verify config file was created
    if [[ ! -f "$nginx_conf" ]]; then
        ui_status "error" "Không thể tạo file config: $nginx_conf"
        return 1
    fi

    # Step 4: Verify config file has content
    if [[ ! -s "$nginx_conf" ]]; then
        ui_status "error" "File config trống: $nginx_conf"
        return 1
    fi

    ui_status "success" "Đã tạo file cấu hình: $nginx_conf ($(wc -l <"$nginx_conf") dòng)"

    # Step 5: Enable site
    if ! ui_run_command "Enable nginx site" "
        ln -sf $nginx_conf /etc/nginx/sites-enabled/
    "; then
        return 1
    fi

    # Step 6: Test nginx config
    if ! ui_run_command "Test nginx configuration" "nginx -t"; then
        ui_status "error" "Nginx config có lỗi, removing site"
        rm -f "/etc/nginx/sites-enabled/$(basename $nginx_conf)"
        return 1
    fi

    # Step 7: Reload nginx
    if ! ui_run_command "Reload nginx" "systemctl reload nginx"; then
        return 1
    fi

    # Step 8: Verify nginx is listening on 443
    sleep 2
    if ss -tlpn | grep -q ":443"; then
        ui_status "success" "Nginx đang listen trên port 443"
    else
        ui_status "warning" "Nginx chưa listen trên port 443, kiểm tra logs"
        tail -n 5 /var/log/nginx/error.log | sed 's/^/  /'
        return 1
    fi

    return 0
}

verify_ssl_setup() {
    local domain="$1"
    local n8n_port="${2:-5678}"

    ui_section "Xác minh cài đặt SSL"

    # 1. Kiểm tra N8N có đang chạy
    local n8n_running=false

    if command_exists docker && docker ps | grep -q "n8n"; then
        ui_status "success" "N8N đang chạy trong Docker"
        n8n_running=true
    elif systemctl is-active --quiet n8n; then
        ui_status "success" "N8N service đang chạy"
        n8n_running=true
    else
        ui_status "warning" "N8N có thể không chạy, đang kiểm tra port..."
        if netstat -tulpn | grep -q ":$n8n_port "; then
            ui_status "success" "Port $n8n_port đang hoạt động"
            n8n_running=true
        else
            ui_status "error" "N8N không chạy, đang khởi động..."
            # Thử khởi động N8N
            if [[ -f "/opt/n8n/docker-compose.yml" ]]; then
                ui_run_command "Khởi động N8N" "
                    cd /opt/n8n && docker compose up -d
                "
            fi
        fi
    fi

    # 2. Kiểm tra file cấu hình Nginx
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"
    if [[ ! -f "$nginx_conf" ]]; then
        ui_status "error" "File cấu hình Nginx không tồn tại: $nginx_conf"
        create_nginx_ssl_config "$domain" "$n8n_port"
    else
        ui_status "success" "File cấu hình Nginx tồn tại"
    fi

    # 3. Kiểm tra nội dung file cấu hình
    ui_run_command "Kiểm tra cấu hình proxy pass" "
        if ! grep -q 'proxy_pass http://127.0.0.1:$n8n_port' $nginx_conf; then
            # Sửa port không đúng
            sed -i 's|proxy_pass http://127.0.0.1:[0-9]*|proxy_pass http://127.0.0.1:$n8n_port|' $nginx_conf
        fi
    "

    # 4. Kiểm tra Nginx đang chạy
    if ! systemctl is-active --quiet nginx; then
        ui_run_command "Khởi động Nginx" "systemctl restart nginx"
    else
        ui_run_command "Tải lại cấu hình Nginx" "nginx -t && systemctl reload nginx"
    fi

    # 5. Cập nhật file hosts (để test)
    ui_run_command "Cập nhật local hosts" "
        if ! grep -q '$domain' /etc/hosts; then
            echo '127.0.0.1 $domain' >> /etc/hosts
        fi
    "

    # 6. Kiểm tra kết nối
    ui_info "Đang kiểm tra kết nối HTTPS..."
    local https_works=false

    if curl -s -k "https://$domain" >/dev/null 2>&1; then
        ui_status "success" "Kết nối HTTPS hoạt động"
        https_works=true
    else
        ui_status "error" "Không thể kết nối HTTPS"

        # Hiển thị logs
        ui_info "10 dòng cuối logs Nginx:"
        tail -n 10 "/var/log/nginx/$domain.error.log"
    fi

    if $n8n_running && ! $https_works; then
        ui_info "N8N đang chạy nhưng HTTPS không hoạt động. Kiểm tra cấu hình Nginx..."
        ui_run_command "Thêm debug logs" "
            sed -i 's|error_log /var/log/nginx/\$host.error.log;|error_log /var/log/nginx/\$host.error.log debug;|' $nginx_conf
            systemctl reload nginx
        "
    fi

    # Hiển thị thông tin hữu ích
    ui_info "Thông tin cấu hình:"
    echo "- Domain: $domain"
    echo "- N8N Port: $n8n_port"
    echo "- SSL Cert: /etc/letsencrypt/live/$domain/fullchain.pem"
    echo "- Nginx Config: $nginx_conf"

    return $([[ "$https_works" == "true" ]] && echo 0 || echo 1)
}

# ===== SSL CERTIFICATE =====

install_certbot() {
    if command_exists certbot; then
        ui_status "success" "Certbot đã cài đặt"
        return 0
    fi

    ui_run_command "Cài đặt Certbot" "
        apt update
        apt install -y certbot python3-certbot-nginx
    "
}

obtain_ssl_certificate() {
    local domain="$1"
    local email="$2"

    # Kiểm tra DNS
    ui_run_command "Kiểm tra DNS settings" "
        echo 'nameserver 8.8.8.8' > /etc/resolv.conf.temp
        echo 'nameserver 1.1.1.1' >> /etc/resolv.conf.temp
        cp /etc/resolv.conf /etc/resolv.conf.backup || true
        cp /etc/resolv.conf.temp /etc/resolv.conf
    "

    # Create webroot directory with proper permissions
    ui_run_command "Chuẩn bị webroot cho HTTP challenge" "
        mkdir -p $WEBROOT_PATH/.well-known/acme-challenge
        chown -R www-data:www-data $WEBROOT_PATH
        chmod -R 755 $WEBROOT_PATH
    "

    # Create initial HTTP-only config for verification
    local temp_conf="/etc/nginx/sites-available/${domain}_temp.conf"

    ui_run_command "Tạo cấu hình tạm cho HTTP challenge" "
        cat > $temp_conf << EOF
server {
    listen 80;
    server_name $domain;

    root $WEBROOT_PATH;
    
    location /.well-known/acme-challenge/ {
        allow all;
    }
    
    location / {
        return 200 'SSL setup in progress';
        add_header Content-Type text/plain;
    }
}
EOF
        ln -sf $temp_conf /etc/nginx/sites-enabled/
        nginx -t && systemctl reload nginx
        
        # Test if the config is working
        sleep 2
        curl -s http://localhost/.well-known/acme-challenge/test-file > /dev/null
    "

    # Create test file in acme-challenge directory
    local test_path="$WEBROOT_PATH/.well-known/acme-challenge/test-file"
    echo "Certbot test" >"$test_path"
    chmod 644 "$test_path"
    chown www-data:www-data "$test_path"

    # Obtain certificate
    if ! ui_run_command "Lấy chứng chỉ SSL từ Let's Encrypt" "
        certbot certonly --webroot \
            -w $WEBROOT_PATH \
            -d $domain \
            --agree-tos \
            --email $email \
            --non-interactive \
            --force-renewal
    "; then
        rm -f "/etc/nginx/sites-enabled/$(basename $temp_conf)"
        systemctl reload nginx
        return 1
    fi

    # Remove temp config
    rm -f "/etc/nginx/sites-enabled/$(basename $temp_conf)"

    # Download SSL options if needed
    if [[ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]]; then
        ui_run_command "Tải cấu hình SSL" "
            curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf -o /etc/letsencrypt/options-ssl-nginx.conf
        "
    fi

    if [[ ! -f /etc/letsencrypt/ssl-dhparams.pem ]]; then
        ui_run_command "Tạo DH parameters" "
            openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
        "
    fi

    return 0
}

cleanup_dns_settings() {
    # Khôi phục file resolv.conf cũ nếu có
    if [[ -f /etc/resolv.conf.backup ]]; then
        mv /etc/resolv.conf.backup /etc/resolv.conf
    fi
}

# ===== AUTO-RENEWAL =====

setup_auto_renewal() {
    ui_section "Cấu hình tự động gia hạn SSL"

    # Enable certbot timer
    if ! ui_run_command "Kích hoạt auto-renewal" "
        systemctl enable certbot.timer
        systemctl start certbot.timer
    "; then
        return 1
    fi

    # Test renewal
    ui_run_command "Test renewal process" "certbot renew --dry-run"

    # Create renewal hook
    local renewal_hook="/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"
    ui_run_command "Tạo renewal hook" "
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > $renewal_hook << 'EOF'
#!/bin/bash
systemctl reload nginx
EOF
        chmod +x $renewal_hook
    "

    ui_status "success" "Auto-renewal đã được cấu hình"
    ui_info_box "Thông tin auto-renewal" \
        "Certbot sẽ tự động kiểm tra gia hạn 2 lần/ngày" \
        "Chứng chỉ sẽ được gia hạn khi còn < 30 ngày" \
        "Nginx sẽ tự động reload sau khi gia hạn"
}

# ===== DOCKER CONFIGURATION UPDATE =====

update_n8n_ssl_config() {
    local domain="$1"
    local compose_dir="/opt/n8n"

    if [[ ! -f "$compose_dir/docker-compose.yml" ]]; then
        ui_status "error" "Không tìm thấy N8N Docker installation"
        return 1
    fi

    ui_run_command "Cập nhật cấu hình N8N cho SSL" "
        cd $compose_dir
        
        # Update .env file
        sed -i 's|^N8N_DOMAIN=.*|N8N_DOMAIN=$domain|' .env
        sed -i 's|^N8N_WEBHOOK_URL=.*|N8N_WEBHOOK_URL=https://$domain|' .env
        
        # Update docker-compose environment
        sed -i 's|N8N_PROTOCOL=http|N8N_PROTOCOL=https|' docker-compose.yml
        sed -i 's|WEBHOOK_URL=http://.*|WEBHOOK_URL=https://$domain/|' docker-compose.yml
        sed -i 's|N8N_HOST=0.0.0.0|N8N_HOST=$domain|' docker-compose.yml
        
        # Restart N8N
        docker compose restart n8n
    "

    # Save to config
    config_set "n8n.domain" "$domain"
    config_set "n8n.ssl_enabled" "true"
    config_set "n8n.webhook_url" "https://$domain"
}

# Chẩn đoán và khắc phục vấn đề SSL
debug_ssl_setup() {
    local domain="$1"

    ui_header "Chẩn đoán vấn đề SSL"

    # 1. Kiểm tra DNS
    ui_section "1. Kiểm tra cấu hình DNS"
    local server_ip=$(get_public_ip)
    local resolved_ip=$(dig +short A "$domain" @1.1.1.1 | tail -n1)

    if [[ -z "$resolved_ip" || "$resolved_ip" != "$server_ip" ]]; then
        ui_status "error" "DNS không trỏ đúng: $domain → ${resolved_ip:-'không tìm thấy'} (cần: $server_ip)"
        echo "Vui lòng cập nhật DNS record để trỏ đến IP server: $server_ip"
        echo "Sau khi cập nhật DNS, đợi 5-10 phút để thay đổi có hiệu lực rồi thử lại."
    else
        ui_status "success" "DNS đã trỏ đúng: $domain → $server_ip"
    fi

    # 2. Kiểm tra cấu hình Nginx
    ui_section "2. Kiểm tra cấu hình Nginx"
    local webroot_path="$WEBROOT_PATH"

    if [[ ! -d "$webroot_path" ]]; then
        ui_run_command "Tạo thư mục webroot" "mkdir -p $webroot_path"
    fi

    ui_run_command "Cấp quyền cho webroot" "
        chown -R www-data:www-data $webroot_path
        chmod -R 755 $webroot_path
    "

    # Tạo file test
    local test_file="$webroot_path/ssl-test.txt"
    echo "SSL setup test file" >"$test_file"
    chown www-data:www-data "$test_file"

    # Tạo cấu hình tạm thời cho Nginx
    ui_run_command "Cấu hình Nginx tạm thời" "
        cat > /etc/nginx/sites-available/${domain}_debug.conf << EOF
server {
    listen 80;
    server_name $domain;
    
    location / {
        root $webroot_path;
        try_files \$uri \$uri/ =404;
    }
    
    location /.well-known/acme-challenge/ {
        root $webroot_path;
        try_files \$uri =404;
    }
}
EOF
        ln -sf /etc/nginx/sites-available/${domain}_debug.conf /etc/nginx/sites-enabled/
        nginx -t && systemctl reload nginx
    "

    # 3. Kiểm tra truy cập từ bên ngoài
    ui_section "3. Kiểm tra truy cập HTTP"
    ui_info "Đang kiểm tra truy cập HTTP đến $domain..."

    if curl -s -o /dev/null -w "%{http_code}" "http://$domain" | grep -q "200\|301\|302"; then
        ui_status "success" "Có thể truy cập HTTP đến $domain"
    else
        ui_status "error" "Không thể truy cập HTTP đến $domain"
        ui_info "Kiểm tra iptables/firewalld để đảm bảo port 80 đã mở"
    fi

    # 4. Kiểm tra truy cập đến file test
    ui_info "Đang kiểm tra truy cập đến file test..."
    if curl -s -o /dev/null -w "%{http_code}" "http://$domain/ssl-test.txt" | grep -q "200"; then
        ui_status "success" "Có thể truy cập file test"
    else
        ui_status "error" "Không thể truy cập file test"
        ui_info "Kiểm tra quyền file và cấu hình Nginx"
    fi

    # 5. Kiểm tra certbot logs
    ui_section "4. Xem logs Let's Encrypt"
    if [[ -f "/var/log/letsencrypt/letsencrypt.log" ]]; then
        ui_info "5 dòng cuối của log certbot:"
        tail -n 5 /var/log/letsencrypt/letsencrypt.log | while read -r line; do
            ui_info "  $line"
        done
    fi

    ui_section "Các bước khắc phục"
    echo "1) Đảm bảo domain $domain trỏ đúng về IP server: $server_ip"
    echo "2) Đảm bảo port 80 đã mở (kiểm tra firewall)"
    echo "3) Kiểm tra nginx đã chạy: systemctl status nginx"
    echo "4) Thử cài đặt SSL với certbot trực tiếp:"
    echo "   certbot certonly --webroot -w $webroot_path -d $domain"
    echo ""

    # Xóa file test và cấu hình tạm thời
    rm -f "$test_file"

    ui_section "Các bước khắc phục"
    echo "1) Đảm bảo domain $domain trỏ đúng về IP server: $server_ip"
    echo "2) Đảm bảo kết nối internet hoạt động và có thể phân giải DNS"
    echo "3) Thử lệnh này để kiểm tra DNS: dig acme-v02.api.letsencrypt.org"
    echo "4) Kiểm tra file /etc/resolv.conf có nameserver hợp lệ"
    echo "5) Thử cài đặt SSL với certbot trực tiếp:"
    echo "   certbot certonly --webroot -w $WEBROOT_PATH -d $domain"
    echo ""
}

# ===== MAIN SSL SETUP FUNCTION =====

setup_ssl_main() {
    ui_header "Cài đặt SSL với Let's Encrypt"

    # Get domain
    echo -n -e "${UI_WHITE}Nhập domain cho N8N: ${UI_NC}"
    read -r domain

    if [[ -z "$domain" ]]; then
        ui_status "error" "Domain không được để trống"
        return 1
    fi

    if ! ui_validate_domain "$domain"; then
        ui_status "error" "Domain không hợp lệ: $domain"
        return 1
    fi

    # Get email
    echo -n -e "${UI_WHITE}Nhập email cho Let's Encrypt: ${UI_NC}"
    read -r email

    if [[ -z "$email" ]]; then
        email="admin@$domain"
        ui_status "info" "Sử dụng email mặc định: $email"
    fi

    if ! ui_validate_email "$email"; then
        ui_status "error" "Email không hợp lệ: $email"
        return 1
    fi

    # Get N8N port
    local n8n_port=$(config_get "n8n.port" "5678")
    echo -n -e "${UI_WHITE}Port N8N (hiện tại: $n8n_port): ${UI_NC}"
    read -r port_input
    if [[ -n "$port_input" ]]; then
        n8n_port="$port_input"
    fi

    ui_info_box "Thông tin SSL setup" \
        "Domain: $domain" \
        "Email: $email" \
        "N8N Port: $n8n_port"

    echo -n -e "${UI_YELLOW}Tiếp tục cài đặt SSL? [Y/n]: ${UI_NC}"
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 0
    fi

    # Validate DNS
    if ! validate_domain_dns "$domain"; then
        ui_status "warning" "DNS validation thất bại nhưng tiếp tục"
    fi

    # Kiểm tra kết nối internet
    ui_run_command "Kiểm tra kết nối internet" "
        ping -c 3 8.8.8.8 > /dev/null || ping -c 3 1.1.1.1 > /dev/null
    " || {
        ui_status "error" "❌ Không thể kết nối internet. Vui lòng kiểm tra lại kết nối mạng."
        return 1
    }

    # Kiểm tra DNS resolution
    ui_run_command "Kiểm tra phân giải DNS" "
        host acme-v02.api.letsencrypt.org > /dev/null || nslookup acme-v02.api.letsencrypt.org > /dev/null
    " || {
        ui_status "warning" "⚠️ Có vấn đề với phân giải DNS. Đang cấu hình DNS tạm thời..."
        echo 'nameserver 8.8.8.8' >/etc/resolv.conf.temp
        echo 'nameserver 1.1.1.1' >>/etc/resolv.conf.temp
        cp /etc/resolv.conf /etc/resolv.conf.backup || true
        cp /etc/resolv.conf.temp /etc/resolv.conf
    }

    # Install dependencies
    install_certbot || return 1

    # Attempt to obtain SSL certificate
    if ! obtain_ssl_certificate "$domain" "$email"; then
        ui_status "error" "❌ Lấy chứng chỉ SSL từ Let's Encrypt - Thất bại"

        # Khôi phục DNS settings
        cleanup_dns_settings

        echo -n -e "${UI_YELLOW}Bạn có muốn tiến hành chẩn đoán sự cố? [Y/n]: ${UI_NC}"
        read -r debug_confirm
        if [[ ! "$debug_confirm" =~ ^[Nn]$ ]]; then
            debug_ssl_setup "$domain"
        fi

        return 1
    fi

    # Khôi phục DNS settings
    cleanup_dns_settings
    # Create Nginx configuration
    create_nginx_ssl_config "$domain" "$n8n_port" || return 1

    # Update N8N configuration
    update_n8n_ssl_config "$domain" || return 1

    # Setup auto-renewal
    setup_auto_renewal || return 1

    # Final verification
    ui_section "Kiểm tra SSL"

    if ! verify_ssl_setup "$domain" "$n8n_port"; then
        ui_status "warning" "SSL đã được cấu hình nhưng có thể có vấn đề với kết nối"
        echo -n -e "${UI_YELLOW}Bạn có muốn thử khởi động lại N8N? [Y/n]: ${UI_NC}"
        read -r restart_confirm

        if [[ ! "$restart_confirm" =~ ^[Nn]$ ]]; then
            if [[ -f "/opt/n8n/docker-compose.yml" ]]; then
                ui_run_command "Khởi động lại N8N" "
                    cd /opt/n8n && docker compose restart
                "
            elif systemctl is-active --quiet n8n; then
                ui_run_command "Khởi động lại N8N" "systemctl restart n8n"
            fi

            # Đợi N8N khởi động
            sleep 5

            # Kiểm tra lại
            verify_ssl_setup "$domain" "$n8n_port"
        fi

        ui_info "Gợi ý khắc phục:"
        echo "1) Kiểm tra N8N đang chạy: docker ps | grep n8n"
        echo "2) Xem logs N8N: cd /opt/n8n && docker compose logs n8n"
        echo "3) Kiểm tra cấu hình Nginx: sudo nginx -t"
        echo "4) Xem logs Nginx: sudo tail -n 50 /var/log/nginx/$domain.error.log"
    else
        ui_status "success" "SSL hoạt động: https://$domain"
    fi

    ui_info_box "SSL setup hoàn tất!" \
        "✅ Chứng chỉ SSL đã được cài đặt" \
        "✅ Auto-renewal đã được cấu hình" \
        "✅ N8N đã được cập nhật cho HTTPS" \
        "🌐 Truy cập: https://$domain"

    return 0
}

# Export main function
export -f setup_ssl_main
