#!/bin/bash

# DataOnline N8N Manager - Database Manager Plugin  
# Phiên bản: 1.0.3 - Simplified Menu (8 core functions)
# Mô tả: NocoDB integration cho quản lý database N8N

set -euo pipefail

# Source core modules
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_PROJECT_ROOT="$(dirname "$(dirname "$PLUGIN_DIR")")"

# Load core modules if not loaded
[[ -z "${LOGGER_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/logger.sh"
[[ -z "${CONFIG_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/config.sh"
[[ -z "${UTILS_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/utils.sh"
[[ -z "${UI_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/ui.sh"
[[ -z "${SPINNER_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/spinner.sh"

# Load sub-modules
source "$PLUGIN_DIR/nocodb-setup.sh"
source "$PLUGIN_DIR/nocodb-management.sh"

# Constants
readonly DATABASE_MANAGER_LOADED=true
readonly NOCODB_PORT=8080
readonly NOCODB_CONTAINER="n8n-nocodb"
readonly N8N_COMPOSE_DIR="/opt/n8n"

# ===== MAIN MENU FUNCTION =====

database_manager_main() {
    ui_header "Quản lý Database N8N với NocoDB"

    while true; do
        show_database_manager_menu
        
        echo -n -e "${UI_WHITE}Chọn [0-8]: ${UI_NC}"
        read -r choice

        case "$choice" in
        1) check_nocodb_status ;;
        2) install_nocodb ;;
        3) open_nocodb_interface ;;
        4) backup_nocodb_config ;;
        5) nocodb_maintenance ;;
        6) show_nocodb_logs ;;
        7) setup_nocodb_ssl ;; 
        8) uninstall_nocodb ;;
        0) return 0 ;;
        *) ui_status "error" "Lựa chọn không hợp lệ" ;;
        esac

        echo ""
        read -p "Nhấn Enter để tiếp tục..."
    done
}

# ===== MENU DISPLAY =====

show_database_manager_menu() {
    local nocodb_status=$(get_nocodb_status)
    local nocodb_url=$(get_nocodb_url)
    
    echo ""
    ui_section "Trạng thái NocoDB"
    echo "Status: $nocodb_status"
    if [[ -n "$nocodb_url" ]]; then
        echo "URL: $nocodb_url"
    fi
    echo ""
    
    echo "🗄️  QUẢN LÝ DATABASE N8N"
    echo ""
    echo "1) 📊 Kiểm tra trạng thái"
    echo "2) 🚀 Cài đặt NocoDB"
    echo "3) 🌐 Mở giao diện NocoDB"
    echo "4) 💾 Backup cấu hình"
    echo "5) 🔧 Bảo trì & tối ưu"
    echo "6) 📝 Xem logs"
    echo "7) 🔒 Cài đặt SSL"
    echo "8) 🗑️  Gỡ cài đặt NocoDB"
    echo "0) ⬅️  Quay lại"
    echo ""
}

# ===== STATUS FUNCTIONS =====

get_nocodb_status() {
    if docker ps --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
        if curl -s "http://localhost:${NOCODB_PORT}/api/v1/health" >/dev/null 2>&1; then
            echo -e "${UI_GREEN}🟢 Hoạt động${UI_NC}"
        else
            echo -e "${UI_YELLOW}🟡 Khởi động${UI_NC}"
        fi
    else
        echo -e "${UI_RED}🔴 Chưa cài đặt${UI_NC}"
    fi
}

get_nocodb_url() {
    local domain=$(config_get "nocodb.domain" "")
    if [[ -n "$domain" ]]; then
        echo "https://$domain"
    else
        local main_domain=$(config_get "n8n.domain" "")
        if [[ -n "$main_domain" ]]; then
            echo "https://db.$main_domain"
        else
            local public_ip=$(get_public_ip || echo "localhost")
            echo "http://$public_ip:8080"
        fi
    fi
}

check_nocodb_status() {
    ui_section "Kiểm tra trạng thái NocoDB chi tiết"
    
    # Check container
    if docker ps --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
        ui_status "success" "Container NocoDB đang chạy"
        
        # Get container info
        local container_id=$(docker ps -q --filter "name=^${NOCODB_CONTAINER}$")
        if [[ -n "$container_id" ]]; then
            echo "Container ID: $container_id"
            echo "Image: $(docker inspect $container_id --format '{{.Config.Image}}')"
            echo "Started: $(docker inspect $container_id --format '{{.State.StartedAt}}' | cut -d'T' -f1)"
            echo "Status: $(docker inspect $container_id --format '{{.State.Status}}')"
        fi
    else
        ui_status "error" "Container NocoDB không chạy"
    fi
    
    # Check API health
    echo ""
    ui_start_spinner "Kiểm tra API health"
    if curl -s "http://localhost:${NOCODB_PORT}/api/v1/health" >/dev/null 2>&1; then
        ui_stop_spinner
        ui_status "success" "NocoDB API phản hồi"
    else
        ui_stop_spinner
        ui_status "error" "NocoDB API không phản hồi"
    fi
    
    # Check database connection
    echo ""
    ui_start_spinner "Kiểm tra kết nối database"
    if test_nocodb_database_connection; then
        ui_stop_spinner
        ui_status "success" "Kết nối database OK"
    else
        ui_stop_spinner
        ui_status "error" "Kết nối database thất bại"
    fi
    
    # Show URLs
    echo ""
    ui_info_box "Thông tin truy cập" \
        "URL: $(get_nocodb_url)" \
        "Port: $NOCODB_PORT" \
        "Admin: $(config_get "nocodb.admin_email" "admin@localhost")"
}

test_nocodb_database_connection() {
    # Test connection through NocoDB API
    local response=$(curl -s "http://localhost:${NOCODB_PORT}/api/v1/db/meta/projects" 2>/dev/null || echo "")
    [[ -n "$response" ]]
}

# ===== QUICK INTERFACE ACCESS =====

open_nocodb_interface() {
    ui_section "Truy cập giao diện NocoDB"
    
    local nocodb_url=$(get_nocodb_url)
    local nocodb_status=$(get_nocodb_status)
    
    if [[ "$nocodb_status" == *"🔴"* ]]; then
        ui_status "error" "NocoDB chưa được cài đặt hoặc không hoạt động"
        echo -n -e "${UI_YELLOW}Bạn có muốn cài đặt NocoDB ngay? [Y/n]: ${UI_NC}"
        read -r install_now
        if [[ ! "$install_now" =~ ^[Nn]$ ]]; then
            install_nocodb
        fi
        return
    fi
    
    ui_info_box "Thông tin đăng nhập NocoDB" \
        "🌐 URL: $nocodb_url" \
        "👤 Email: $(config_get "nocodb.admin_email" "admin@localhost")" \
        "🔑 Password: $(get_nocodb_admin_password)" \
        "" \
        "💡 Tip: Bookmark URL này để truy cập nhanh"
    
    # Show N8N database connection info
    local n8n_postgres_password=$(grep "POSTGRES_PASSWORD=" "$N8N_COMPOSE_DIR/.env" | cut -d'=' -f2 2>/dev/null || echo "N/A")
    ui_info_box "Kết nối N8N Database trong NocoDB" \
        "Host: postgres (hoặc IP server)" \
        "Port: 5432" \
        "Database: n8n" \
        "User: n8n" \
        "Password: $n8n_postgres_password" \
        "" \
        "💡 Sử dụng thông tin này để kết nối N8N data trong NocoDB"
    
    # Try to open in browser if possible
    if command_exists xdg-open; then
        echo -n -e "${UI_YELLOW}Mở trong browser? [Y/n]: ${UI_NC}"
        read -r open_browser
        if [[ ! "$open_browser" =~ ^[Nn]$ ]]; then
            xdg-open "$nocodb_url" 2>/dev/null &
            ui_status "success" "Đã mở browser"
        fi
    elif command_exists open; then  # macOS
        echo -n -e "${UI_YELLOW}Mở trong browser? [Y/n]: ${UI_NC}"
        read -r open_browser
        if [[ ! "$open_browser" =~ ^[Nn]$ ]]; then
            open "$nocodb_url" 2>/dev/null &
            ui_status "success" "Đã mở browser"
        fi
    fi
}

get_nocodb_admin_password() {
    local password_file="$N8N_COMPOSE_DIR/.nocodb-admin-password"
    if [[ -f "$password_file" ]]; then
        cat "$password_file"
    else
        echo "Xem trong file .env: NOCODB_ADMIN_PASSWORD"
    fi
}

# ===== INSTALLATION ENTRY POINT =====

install_nocodb() {
    ui_header "Cài đặt NocoDB Database Manager"
    
    # Check prerequisites
    if ! check_nocodb_prerequisites; then
        ui_status "error" "Yêu cầu hệ thống chưa đáp ứng"
        return 1
    fi
    
    # Confirm installation
    ui_warning_box "Xác nhận cài đặt" \
        "Sẽ thêm NocoDB vào N8N stack hiện tại" \
        "Port sử dụng: $NOCODB_PORT" \
        "Dữ liệu sẽ kết nối với PostgreSQL N8N"
    
    if ! ui_confirm "Tiếp tục cài đặt NocoDB?"; then
        return 0
    fi
    
    # Run installation
    if setup_nocodb_integration; then
        ui_status "success" "🎉 NocoDB đã được cài đặt thành công!"
        
        ui_info_box "Bước tiếp theo" \
            "1. Truy cập giao diện (option 3)" \
            "2. Tạo connection tới N8N database" \
            "3. Tạo views và dashboards theo nhu cầu"
    else
        ui_status "error" "Cài đặt NocoDB thất bại"
        return 1
    fi
}

check_nocodb_prerequisites() {
    ui_section "Kiểm tra yêu cầu hệ thống"
    
    local errors=0
    
    # Check N8N installation
    if [[ ! -f "$N8N_COMPOSE_DIR/docker-compose.yml" ]]; then
        ui_status "error" "N8N chưa được cài đặt"
        ((errors++))
    else
        ui_status "success" "N8N đã cài đặt"
    fi
    
    # Check Docker
    if ! command_exists docker; then
        ui_status "error" "Docker chưa cài đặt"
        ((errors++))
    else
        ui_status "success" "Docker available"
    fi
    
    # Check port availability
    if ! is_port_available $NOCODB_PORT; then
        ui_status "error" "Port $NOCODB_PORT đã được sử dụng"
        ((errors++))
    else
        ui_status "success" "Port $NOCODB_PORT available"
    fi
    
    # Check PostgreSQL
    if ! docker ps --format '{{.Names}}' | grep -q "postgres"; then
        ui_status "error" "PostgreSQL container không chạy"
        ((errors++))
    else
        ui_status "success" "PostgreSQL container OK"
    fi
    
    # Check disk space (minimum 1GB)
    local free_space_gb=$(df -BG "$N8N_COMPOSE_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ "$free_space_gb" -lt 1 ]]; then
        ui_status "error" "Cần ít nhất 1GB dung lượng trống"
        ((errors++))
    else
        ui_status "success" "Dung lượng: ${free_space_gb}GB"
    fi
    
    return $errors
}

# ===== SSL SETUP FUNCTION =====

setup_nocodb_ssl() {
    local main_domain=$(config_get "n8n.domain" "")
    local subdomain="db.$main_domain"
    
    if [[ -z "$main_domain" ]]; then
        echo -n -e "${UI_WHITE}Nhập domain chính (VD: n8n-store.xyz): ${UI_NC}"
        read -r main_domain
        config_set "n8n.domain" "$main_domain"
        subdomain="db.$main_domain"
    fi
    
    ui_info_box "SSL Setup cho NocoDB" \
        "Domain: $subdomain" \
        "Port: 8080 → 443" \
        "Certificate: Let's Encrypt"
    
    if ! ui_confirm "Setup SSL cho $subdomain?"; then
        return 0
    fi
    
    # Check if SSL plugin exists
    local ssl_plugin="$PLUGIN_PROJECT_ROOT/plugins/ssl/main.sh"
    ui_status "info" "Đang kiểm tra SSL plugin tại: $ssl_plugin"
    if [[ -f "$ssl_plugin" ]]; then
        # Use existing SSL plugin logic
        source "$ssl_plugin"
        
        # Create nginx config for subdomain
        create_nocodb_nginx_config "$subdomain"
        
        # Get SSL certificate
        obtain_nocodb_ssl_certificate "$subdomain"
        
        # Update NocoDB config
        update_nocodb_ssl_config "$subdomain"
    else
        ui_status "error" "SSL plugin không tồn tại tại đường dẫn: $ssl_plugin"
        ui_status "info" "Vui lòng kiểm tra lại biến PLUGIN_PROJECT_ROOT hoặc đường dẫn src/plugins/ssl/main.sh."
    fi
}

create_nocodb_nginx_config() {
    local subdomain="$1"
    local nginx_conf="/etc/nginx/sites-available/${subdomain}.conf"
    
    ui_start_spinner "Tạo Nginx config cho $subdomain"
    
    sudo tee "$nginx_conf" > /dev/null << EOF
server {
    listen 80;
    server_name $subdomain;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $subdomain;

    ssl_certificate /etc/letsencrypt/live/$subdomain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$subdomain/privkey.pem;
    
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 100M;
    
    access_log /var/log/nginx/$subdomain.access.log;
    error_log /var/log/nginx/$subdomain.error.log;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
        
        proxy_buffering off;
        proxy_read_timeout 7200s;
        proxy_send_timeout 7200s;
    }
}
EOF

    # Enable site
    sudo ln -sf "$nginx_conf" /etc/nginx/sites-enabled/
    
    ui_stop_spinner
    ui_status "success" "Nginx config tạo thành công"
}

obtain_nocodb_ssl_certificate() {
    local subdomain="$1"
    local email="admin@$(config_get "n8n.domain")"
    
    # Ensure webroot exists
    sudo mkdir -p /var/www/html/.well-known/acme-challenge
    sudo chown -R www-data:www-data /var/www/html
    
    # Test nginx config
    if ! sudo nginx -t; then
        ui_status "error" "Nginx config có lỗi"
        return 1
    fi
    
    # Reload nginx
    sudo systemctl reload nginx
    
    ui_start_spinner "Lấy SSL certificate cho $subdomain"
    
    if sudo certbot certonly --webroot \
        -w /var/www/html \
        -d "$subdomain" \
        --agree-tos \
        --email "$email" \
        --non-interactive; then
        ui_stop_spinner
        ui_status "success" "SSL certificate thành công"
    else
        ui_stop_spinner
        ui_status "error" "SSL certificate thất bại"
        return 1
    fi
    
    # Reload nginx with SSL
    sudo systemctl reload nginx
}

update_nocodb_ssl_config() {
    local subdomain="$1"
    
    ui_start_spinner "Cập nhật NocoDB config"
    
    # Update .env
    sed -i "s|NOCODB_PUBLIC_URL=.*|NOCODB_PUBLIC_URL=https://$subdomain|" "$N8N_COMPOSE_DIR/.env"
    
    # Save to manager config
    config_set "nocodb.domain" "$subdomain"
    config_set "nocodb.ssl_enabled" "true"
    
    # Restart NocoDB
    cd "$N8N_COMPOSE_DIR"
    docker compose restart nocodb
    
    ui_stop_spinner
    ui_status "success" "NocoDB config cập nhật thành công"
}

# ===== UNINSTALL FUNCTION =====

uninstall_nocodb() {
    ui_section "Gỡ cài đặt NocoDB"
    
    ui_warning_box "⚠️  CẢNH BÁO" \
        "Sẽ xóa hoàn toàn NocoDB và cấu hình" \
        "Dữ liệu N8N sẽ không bị ảnh hưởng" \
        "Views và dashboard sẽ bị mất"
    
    if ! ui_confirm "Bạn chắc chắn muốn gỡ NocoDB?"; then
        return 0
    fi
    
    # Backup trước khi xóa
    echo -n -e "${UI_YELLOW}Backup cấu hình trước khi xóa? [Y/n]: ${UI_NC}"
    read -r backup_first
    if [[ ! "$backup_first" =~ ^[Nn]$ ]]; then
        backup_nocodb_config
    fi
    
    # Remove NocoDB
    if remove_nocodb_integration; then
        ui_status "success" "NocoDB đã được gỡ bỏ hoàn toàn"
    else
        ui_status "error" "Gỡ bỏ NocoDB thất bại"
        return 1
    fi
}

# Export main function
export -f database_manager_main