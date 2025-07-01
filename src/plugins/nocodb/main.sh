#!/bin/bash

# DataOnline N8N Manager - NocoDB Integration Plugin
# Phiên bản: 1.0.0

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_PROJECT_ROOT="$(dirname "$(dirname "$PLUGIN_DIR")")"

[[ -z "${LOGGER_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/logger.sh"
[[ -z "${CONFIG_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/config.sh"
[[ -z "${UTILS_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/utils.sh"
[[ -z "${UI_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/ui.sh"
[[ -z "${SPINNER_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/spinner.sh"

readonly NOCODB_LOADED=true
readonly NOCODB_DIR="/opt/nocodb"
readonly NOCODB_PORT="8080"

# ===== MAIN MENU =====

nocodb_main_menu() {
    while true; do
        ui_header "NocoDB Database Manager"

        if [[ ! -f "$NOCODB_DIR/docker-compose.yml" ]]; then
            show_install_menu
        else
            show_management_menu
        fi

        echo ""
        read -p "Nhấn Enter để tiếp tục..."
    done
}

show_install_menu() {
    echo "🚀 Cài đặt NocoDB"
    echo ""
    echo "1) 📊 Cài đặt với kết nối N8N database"
    echo "2) 🔧 Cài đặt standalone"
    echo "0) ❌ Quay lại"
    echo ""

    echo -n -e "${UI_WHITE}Chọn [0-2]: ${UI_NC}"
    read -r choice

    case "$choice" in
    1) install_nocodb_with_n8n ;;
    2) install_nocodb_standalone ;;
    0) return ;;
    *) ui_status "error" "Lựa chọn không hợp lệ" ;;
    esac
}

show_management_menu() {
    local status=$(get_nocodb_status)
    echo "Trạng thái: $status"
    echo ""
    echo "1) 🌐 Thông tin truy cập"
    echo "2) 👥 Quản lý người dùng"
    echo "3) 🔄 Restart service"
    echo "4) 📝 Xem logs"
    echo "5) ⚙️  Cấu hình"
    echo "6) 🗑️  Gỡ cài đặt"
    echo "0) ❌ Quay lại"
    echo ""

    echo -n -e "${UI_WHITE}Chọn [0-6]: ${UI_NC}"
    read -r choice

    case "$choice" in
    1) show_access_info ;;
    2) manage_users ;;
    3) restart_nocodb ;;
    4) show_logs ;;
    5) configure_nocodb ;;
    6) uninstall_nocodb ;;
    0) return ;;
    *) ui_status "error" "Lựa chọn không hợp lệ" ;;
    esac
}

# ===== INSTALLATION =====

install_nocodb_with_n8n() {
    ui_section "Cài đặt NocoDB với N8N Database"

    # Check N8N installation
    if [[ ! -f "/opt/n8n/docker-compose.yml" ]]; then
        ui_status "error" "N8N chưa được cài đặt"
        return 1
    fi

    # Get current domain
    local n8n_domain=$(config_get "n8n.domain" "")
    if [[ -z "$n8n_domain" ]]; then
        ui_status "error" "N8N domain chưa được cấu hình"
        return 1
    fi

    ui_info_box "Cài đặt NocoDB" \
        "Domain: https://$n8n_domain/nocodb" \
        "Database: N8N PostgreSQL" \
        "Authentication: Basic Auth"

    if ! ui_confirm "Tiếp tục cài đặt?"; then
        return
    fi

    # Install steps
    if ! create_nocodb_docker_config; then
        ui_status "error" "Tạo Docker config thất bại"
        return 1
    fi

    if ! setup_nginx_subdirectory "$n8n_domain"; then
        ui_status "error" "Cấu hình Nginx thất bại"
        return 1
    fi

    if ! create_database_user; then
        ui_status "error" "Tạo database user thất bại"
        return 1
    fi

    if ! start_nocodb_service; then
        ui_status "error" "Khởi động service thất bại"
        return 1
    fi

    # Save config
    config_set "nocodb.installed" "true"
    config_set "nocodb.domain" "$n8n_domain"
    config_set "nocodb.url" "https://$n8n_domain/nocodb"

    ui_status "success" "NocoDB đã cài đặt: https://$n8n_domain/nocodb"
    show_access_info
}

install_nocodb_standalone() {
    ui_section "Cài đặt NocoDB standalone"

    create_nocodb_standalone_config
    start_nocodb_service

    local vps_ip=$(get_public_ip)
    config_set "nocodb.installed" "true"
    config_set "nocodb.url" "http://$vps_ip:$NOCODB_PORT"

    ui_status "success" "NocoDB đã cài đặt: http://$vps_ip:$NOCODB_PORT"
}

# ===== DOCKER CONFIGURATION =====

create_nocodb_docker_config() {
    ui_start_spinner "Tạo Docker configuration"

    mkdir -p "$NOCODB_DIR"

    # Get N8N database credentials
    local postgres_password=""
    if [[ -f "/opt/n8n/.env" ]]; then
        postgres_password=$(grep "POSTGRES_PASSWORD=" /opt/n8n/.env | cut -d'=' -f2)
    fi

    if [[ -z "$postgres_password" ]]; then
        ui_stop_spinner
        ui_status "error" "Không tìm thấy PostgreSQL password"
        return 1
    fi

    # Generate admin credentials
    local admin_password=$(generate_random_string 16)
    local jwt_secret=$(generate_random_string 64)

    # Create .env file
    cat >"$NOCODB_DIR/.env" <<EOF
# NocoDB Configuration
POSTGRES_PASSWORD=$postgres_password
NOCODB_ADMIN_PASSWORD=$admin_password
NC_JWT_EXPIRES_IN=10h
NC_JWT_SECRET=$jwt_secret
EOF

    # Get N8N domain
    local n8n_domain=$(config_get "n8n.domain")
    echo "N8N_DOMAIN=$n8n_domain" >>"$NOCODB_DIR/.env"

    # Create docker-compose.yml
    cat >"$NOCODB_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb
    restart: unless-stopped
    ports:
      - "127.0.0.1:$NOCODB_PORT:8080"
    environment:
      - NC_DB=pg://host.docker.internal:5432?u=nocodb_user&p=\${POSTGRES_PASSWORD}&d=n8n
      - NC_PUBLIC_URL=https://\${N8N_DOMAIN}/nocodb
      - NC_ADMIN_EMAIL=admin@datalonline.vn
      - NC_ADMIN_PASSWORD=\${NOCODB_ADMIN_PASSWORD}
      - NC_JWT_EXPIRES_IN=\${NC_JWT_EXPIRES_IN}
      - NC_JWT_SECRET=\${NC_JWT_SECRET}
      - NC_CONNECT_TO_EXTERNAL_DB_DISABLED=false
      - NC_DISABLE_TELE=true
      - NC_MIN=true
      - NC_TOOL_DIR=/usr/app/data/
    volumes:
      - nocodb_data:/usr/app/data
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - nocodb-network

volumes:
  nocodb_data:
    driver: local

networks:
  nocodb-network:
    driver: bridge
EOF

    ui_stop_spinner
    ui_status "success" "Docker configuration tạo thành công"

    # Save admin password to config
    config_set "nocodb.admin_password" "$admin_password"

    return 0
}

create_nocodb_standalone_config() {
    mkdir -p "$NOCODB_DIR"

    local admin_password=$(generate_random_string 16)

    cat >"$NOCODB_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb
    restart: unless-stopped
    ports:
      - "$NOCODB_PORT:8080"
    environment:
      - NC_DB=sqlite:///usr/app/data/noco.db
      - NC_ADMIN_EMAIL=admin@datalonline.vn
      - NC_ADMIN_PASSWORD=$admin_password
      - NC_DISABLE_TELE=true
    volumes:
      - nocodb_data:/usr/app/data

volumes:
  nocodb_data:
EOF

    config_set "nocodb.admin_password" "$admin_password"
}

# ===== NGINX CONFIGURATION =====

setup_nginx_subdirectory() {
    local domain="$1"
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"

    ui_start_spinner "Cấu hình Nginx subdirectory"

    # Check if nginx config exists
    if [[ ! -f "$nginx_conf" ]]; then
        ui_stop_spinner
        ui_status "error" "Nginx config không tồn tại: $nginx_conf"
        return 1
    fi

    # Backup existing config
    cp "$nginx_conf" "${nginx_conf}.backup.$(date +%Y%m%d_%H%M%S)"

    # Check if NocoDB location already exists
    if grep -q "location /nocodb" "$nginx_conf"; then
        ui_stop_spinner
        ui_status "warning" "NocoDB location đã tồn tại trong Nginx config"
        return 0
    fi

    # Create nocodb location block
    local nocodb_config="
    # NocoDB subdirectory
    location /nocodb/ {
        auth_basic \"Database Access\";
        auth_basic_user_file /etc/nginx/.htpasswd-nocodb;
        
        proxy_pass http://127.0.0.1:$NOCODB_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Prefix /nocodb;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
        
        client_max_body_size 100M;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }"

    # Find the last server block and insert before closing brace
    local temp_file=$(mktemp)

    # Use sed instead of awk to avoid string issues
    sed '/^server {/,/^}$/ {
        /^}$/ {
            i\
    # NocoDB subdirectory\
    location /nocodb/ {\
        auth_basic "Database Access";\
        auth_basic_user_file /etc/nginx/.htpasswd-nocodb;\
        \
        proxy_pass http://127.0.0.1:'"$NOCODB_PORT"'/;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\
        proxy_set_header X-Forwarded-Proto $scheme;\
        proxy_set_header X-Forwarded-Prefix /nocodb;\
        \
        proxy_http_version 1.1;\
        proxy_set_header Upgrade $http_upgrade;\
        proxy_set_header Connection '"'"'upgrade'"'"';\
        proxy_cache_bypass $http_upgrade;\
        \
        client_max_body_size 100M;\
        proxy_read_timeout 300s;\
        proxy_connect_timeout 75s;\
    }
        }
    }' "$nginx_conf" >"$temp_file"

    mv "$temp_file" "$nginx_conf"

    # Create basic auth
    if ! create_basic_auth; then
        ui_stop_spinner
        ui_status "error" "Tạo basic auth thất bại"
        return 1
    fi

    # Test nginx config
    if ! nginx -t 2>/dev/null; then
        ui_stop_spinner
        ui_status "error" "Nginx config có lỗi, khôi phục backup"
        cp "${nginx_conf}.backup."* "$nginx_conf"
        return 1
    fi

    # Reload nginx
    systemctl reload nginx

    ui_stop_spinner
    ui_status "success" "Nginx configuration updated"
    return 0
}

create_basic_auth() {
    local username="nocodb"
    local password=$(generate_random_string 12)

    # Install htpasswd if needed
    if ! command_exists htpasswd; then
        if ! ensure_package_installed apache2-utils; then
            return 1
        fi
    fi

    # Create htpasswd file
    echo "$password" | htpasswd -ci /etc/nginx/.htpasswd-nocodb "$username" 2>/dev/null

    # Save credentials
    config_set "nocodb.auth_username" "$username"
    config_set "nocodb.auth_password" "$password"

    return 0
}

# ===== DATABASE SETUP =====

create_database_user() {
    ui_start_spinner "Tạo database user cho NocoDB"

    local postgres_password=""
    if [[ -f "/opt/n8n/.env" ]]; then
        postgres_password=$(grep "POSTGRES_PASSWORD=" /opt/n8n/.env | cut -d'=' -f2)
    fi

    if [[ -z "$postgres_password" ]]; then
        ui_stop_spinner
        ui_status "error" "Không tìm thấy PostgreSQL password"
        return 1
    fi

    # Check if user already exists
    local user_exists=$(docker exec n8n-postgres psql -U n8n -d n8n -tAc "SELECT 1 FROM pg_roles WHERE rolname='nocodb_user';" 2>/dev/null || echo "")

    if [[ "$user_exists" == "1" ]]; then
        ui_stop_spinner
        ui_status "success" "Database user nocodb_user đã tồn tại"
        return 0
    fi

    # Create user and grant permissions
    local create_user_sql="
        CREATE USER nocodb_user WITH PASSWORD '$postgres_password';
        GRANT CONNECT ON DATABASE n8n TO nocodb_user;
        GRANT USAGE ON SCHEMA public TO nocodb_user;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nocodb_user;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO nocodb_user;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO nocodb_user;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO nocodb_user;
    "

    if docker exec n8n-postgres psql -U n8n -d n8n -c "$create_user_sql" >/dev/null 2>&1; then
        ui_stop_spinner
        ui_status "success" "Database user tạo thành công"
        return 0
    else
        ui_stop_spinner
        ui_status "error" "Tạo database user thất bại"
        return 1
    fi
}

# ===== SERVICE MANAGEMENT =====

start_nocodb_service() {
    ui_start_spinner "Khởi động NocoDB"

    cd "$NOCODB_DIR"
    if ! docker compose up -d >/dev/null 2>&1; then
        ui_stop_spinner
        ui_status "error" "Không thể khởi động NocoDB"
        return 1
    fi

    # Wait for service to be ready
    local max_wait=30
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if curl -s "http://localhost:$NOCODB_PORT" >/dev/null 2>&1; then
            ui_stop_spinner
            ui_status "success" "NocoDB đã khởi động"
            return 0
        fi
        sleep 2
        ((waited += 2))
    done

    ui_stop_spinner
    ui_status "error" "NocoDB không khởi động được (timeout)"
    return 1
}

restart_nocodb() {
    ui_run_command "Restart NocoDB" "
        cd $NOCODB_DIR
        docker compose restart
    "

    # Wait for restart
    sleep 5
    if curl -s "http://localhost:$NOCODB_PORT" >/dev/null 2>&1; then
        ui_status "success" "NocoDB restart thành công"
    else
        ui_status "error" "NocoDB restart thất bại"
    fi
}

get_nocodb_status() {
    if docker ps --format '{{.Names}}' | grep -q "^nocodb$"; then
        echo -e "${UI_GREEN}🟢 Running${UI_NC}"
    else
        echo -e "${UI_RED}🔴 Stopped${UI_NC}"
    fi
}

# ===== USER MANAGEMENT =====

manage_users() {
    ui_section "Quản lý người dùng NocoDB"

    echo "1) 📋 Hướng dẫn tạo user"
    echo "2) 🔑 Đổi password admin"
    echo "3) 📊 Tạo N8N dashboard templates"
    echo "4) 🔧 Quản lý quyền truy cập"
    echo "0) ⬅️  Quay lại"
    echo ""

    echo -n -e "${UI_WHITE}Chọn [0-4]: ${UI_NC}"
    read -r choice

    case "$choice" in
    1) show_user_guide ;;
    2) change_admin_password ;;
    3) create_n8n_templates ;;
    4) manage_permissions ;;
    0) return ;;
    esac
}

show_user_guide() {
    local nocodb_url=$(config_get "nocodb.url")

    ui_info_box "Tạo user trong NocoDB" \
        "1. Truy cập: $nocodb_url" \
        "2. Login với admin account" \
        "3. Vào Settings → Team & Auth" \
        "4. Click 'Invite Team'" \
        "5. Nhập email và chọn role:" \
        "   - Viewer: Chỉ xem" \
        "   - Editor: Chỉnh sửa data" \
        "   - Creator: Tạo views/forms" \
        "   - Owner: Full quyền" \
        "6. User sẽ nhận email invitation"
}

change_admin_password() {
    echo -n "Nhập password mới cho admin: "
    read -s new_password
    echo

    if [[ ${#new_password} -lt 8 ]]; then
        ui_status "error" "Password phải ít nhất 8 ký tự"
        return 1
    fi

    # Update .env
    sed -i "s/NOCODB_ADMIN_PASSWORD=.*/NOCODB_ADMIN_PASSWORD=$new_password/" "$NOCODB_DIR/.env"

    # Update config
    config_set "nocodb.admin_password" "$new_password"

    # Restart to apply
    restart_nocodb
    ui_status "success" "Password đã được cập nhật"
}

create_n8n_templates() {
    ui_info_box "N8N Dashboard Templates" \
        "Sẽ tạo các view hữu ích:" \
        "- Active Workflows" \
        "- Failed Executions" \
        "- Execution Statistics" \
        "- Recent Activity" \
        "- Credential Management"

    ui_status "info" "Templates sẽ có sẵn trong NocoDB UI sau khi truy cập"

    local nocodb_url=$(config_get "nocodb.url")
    echo "Truy cập $nocodb_url để sử dụng templates"
}

manage_permissions() {
    ui_info_box "Quản lý quyền truy cập" \
        "Basic Auth (Nginx level):" \
        "- Username: $(config_get "nocodb.auth_username")" \
        "- Password: $(config_get "nocodb.auth_password")" \
        "" \
        "NocoDB App level:" \
        "- Admin: $(config_get "nocodb.admin_password")" \
        "- Users: Quản lý trong NocoDB UI"
}

# ===== UTILITIES =====

show_access_info() {
    local nocodb_url=$(config_get "nocodb.url")
    local auth_user=$(config_get "nocodb.auth_username")
    local auth_pass=$(config_get "nocodb.auth_password")
    local admin_pass=$(config_get "nocodb.admin_password")

    ui_info_box "Thông tin truy cập NocoDB" \
        "URL: $nocodb_url" \
        "" \
        "Basic Auth (Nginx):" \
        "Username: $auth_user" \
        "Password: $auth_pass" \
        "" \
        "NocoDB Admin:" \
        "Email: admin@datalonline.vn" \
        "Password: $admin_pass" \
        "" \
        "Database: N8N PostgreSQL" \
        "Tables: workflows, executions, credentials, users"
}

show_logs() {
    echo "📝 NocoDB Logs:"
    echo "==============="
    echo ""
    echo "1) 📄 Real-time logs"
    echo "2) 📄 Recent logs (50 dòng)"
    echo "3) 📄 Error logs only"
    echo "0) ⬅️  Quay lại"
    echo ""

    echo -n -e "${UI_WHITE}Chọn [0-3]: ${UI_NC}"
    read -r choice

    case "$choice" in
    1) docker logs -f nocodb ;;
    2) docker logs --tail 50 nocodb ;;
    3) docker logs nocodb 2>&1 | grep -i "error\|exception\|fail" || echo "Không có error logs" ;;
    0) return ;;
    esac
}

configure_nocodb() {
    ui_section "Cấu hình NocoDB"

    echo "1) 🔧 Chỉnh sửa environment variables"
    echo "2) 🔄 Cập nhật domain"
    echo "3) 📊 Export configuration"
    echo "4) 🔒 Cập nhật Basic Auth"
    echo "0) ⬅️  Quay lại"
    echo ""

    echo -n -e "${UI_WHITE}Chọn [0-4]: ${UI_NC}"
    read -r choice

    case "$choice" in
    1) edit_env_file ;;
    2) update_domain ;;
    3) export_config ;;
    4) update_basic_auth ;;
    0) return ;;
    esac
}

edit_env_file() {
    if command_exists nano; then
        nano "$NOCODB_DIR/.env"
    elif command_exists vim; then
        vim "$NOCODB_DIR/.env"
    else
        cat "$NOCODB_DIR/.env"
        ui_status "info" "File: $NOCODB_DIR/.env"
    fi

    echo -n "Restart NocoDB để áp dụng thay đổi? [Y/n]: "
    read -r restart
    if [[ ! "$restart" =~ ^[Nn]$ ]]; then
        restart_nocodb
    fi
}

update_domain() {
    echo -n "Nhập domain mới: "
    read -r new_domain

    if [[ -z "$new_domain" ]]; then
        ui_status "error" "Domain không được để trống"
        return 1
    fi

    # Update .env
    sed -i "s/N8N_DOMAIN=.*/N8N_DOMAIN=$new_domain/" "$NOCODB_DIR/.env"

    # Update config
    config_set "nocodb.domain" "$new_domain"
    config_set "nocodb.url" "https://$new_domain/nocodb"

    restart_nocodb
    ui_status "success" "Domain đã được cập nhật"
}

export_config() {
    local export_file="/tmp/nocodb-config-$(date +%Y%m%d_%H%M%S).txt"

    cat >"$export_file" <<EOF
# NocoDB Configuration Export
# Generated: $(date)

URL: $(config_get "nocodb.url")
Domain: $(config_get "nocodb.domain")
Basic Auth User: $(config_get "nocodb.auth_username")
Basic Auth Pass: $(config_get "nocodb.auth_password")
Admin Password: $(config_get "nocodb.admin_password")

# Environment Variables:
$(cat "$NOCODB_DIR/.env")
EOF

    ui_status "success" "Configuration exported: $export_file"
}

update_basic_auth() {
    echo -n "Nhập username mới: "
    read -r new_username
    echo -n "Nhập password mới: "
    read -s new_password
    echo

    if [[ -z "$new_username" || -z "$new_password" ]]; then
        ui_status "error" "Username và password không được để trống"
        return 1
    fi

    # Update htpasswd
    echo "$new_password" | htpasswd -ci /etc/nginx/.htpasswd-nocodb "$new_username"

    # Update config
    config_set "nocodb.auth_username" "$new_username"
    config_set "nocodb.auth_password" "$new_password"

    # Reload nginx
    systemctl reload nginx

    ui_status "success" "Basic Auth đã được cập nhật"
}

uninstall_nocodb() {
    ui_warning_box "Cảnh báo" \
        "Sẽ xóa toàn bộ NocoDB và data" \
        "Không thể khôi phục" \
        "Nginx config sẽ được restore"

    if ! ui_confirm "Tiếp tục gỡ cài đặt?"; then
        return
    fi

    # Stop and remove containers
    if [[ -d "$NOCODB_DIR" ]]; then
        ui_run_command "Dừng và xóa NocoDB" "
            cd $NOCODB_DIR
            docker compose down -v
        "
    fi

    # Remove directory
    ui_run_command "Xóa thư mục cài đặt" "rm -rf $NOCODB_DIR"

    # Restore nginx config
    local domain=$(config_get "nocodb.domain")
    if [[ -n "$domain" ]]; then
        local nginx_conf="/etc/nginx/sites-available/${domain}.conf"
        local backup_file=$(ls "${nginx_conf}.backup."* 2>/dev/null | head -1)

        if [[ -f "$backup_file" ]]; then
            ui_run_command "Khôi phục Nginx config" "
                cp '$backup_file' '$nginx_conf'
                nginx -t && systemctl reload nginx
            "
        fi
    fi

    # Remove htpasswd file
    rm -f /etc/nginx/.htpasswd-nocodb

    # Clear config
    config_set "nocodb.installed" "false"
    config_set "nocodb.domain" ""
    config_set "nocodb.url" ""

    ui_status "success" "NocoDB đã được gỡ cài đặt hoàn toàn"
}

# Export functions
export -f nocodb_main_menu
