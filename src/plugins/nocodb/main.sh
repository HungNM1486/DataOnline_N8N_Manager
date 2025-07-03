#!/bin/bash

# DataOnline N8N Manager - NocoDB N8N Data Manager
# Phiên bản: 2.0.0

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
readonly DEFAULT_PORT="8080"
readonly BACKUP_DIR="/opt/n8n/backups/nocodb"

# ===== CORE FUNCTIONS =====

nocodb_main_menu() {
    while true; do
        ui_header "NocoDB - N8N Data Manager"

        if is_nocodb_installed; then
            show_management_menu
        else
            show_install_menu
        fi

        echo ""
        read -p "Nhấn Enter để tiếp tục..."
    done
}

is_nocodb_installed() {
    [[ -f "$NOCODB_DIR/docker-compose.yml" ]]
}

show_install_menu() {
    echo "🚀 Cài đặt NocoDB cho N8N"
    echo ""
    echo "1) 📊 Cài đặt với quyền đầy đủ (cho admin)"
    echo "2) 👁️  Cài đặt chế độ chỉ xem (an toàn)"
    echo "0) ❌ Quay lại"
    echo ""

    echo -n -e "${UI_WHITE}Chọn [0-2]: ${UI_NC}"
    read -r choice

    case "$choice" in
    1) install_nocodb_full_access ;;
    2) install_nocodb_readonly ;;
    0) return ;;
    *) ui_status "error" "Lựa chọn không hợp lệ" ;;
    esac
}

show_management_menu() {
    local status=$(get_nocodb_status)
    echo "Trạng thái: $status"
    echo ""
    echo "1) 🌐 Thông tin truy cập"
    echo "2) 👥 Quản lý quyền truy cập"
    echo "3) 📚 Hướng dẫn sử dụng N8N tables"
    echo "4) 💾 Backup data trước khi sửa"
    echo "5) 🔄 Restart service"
    echo "6) 📝 Xem logs"
    echo "7) 🗑️  Gỡ cài đặt"
    echo "0) ❌ Quay lại"
    echo ""

    echo -n -e "${UI_WHITE}Chọn [0-7]: ${UI_NC}"
    read -r choice

    case "$choice" in
    1) show_access_info ;;
    2) manage_access_permissions ;;
    3) show_n8n_tables_guide ;;
    4) backup_n8n_data ;;
    5) restart_nocodb ;;
    6) show_logs ;;
    7) uninstall_nocodb ;;
    0) return ;;
    *) ui_status "error" "Lựa chọn không hợp lệ" ;;
    esac
}

# ===== VALIDATION FUNCTIONS =====

validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        ui_status "error" "Domain format không hợp lệ"
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1024 ]] || [[ "$port" -gt 65535 ]]; then
        ui_status "error" "Port không hợp lệ (1024-65535)"
        return 1
    fi
    if ! is_port_available "$port"; then
        ui_status "error" "Port $port đã được sử dụng"
        return 1
    fi
    return 0
}

# ===== INSTALLATION FUNCTIONS =====

install_nocodb_full_access() {
    ui_section "Cài đặt NocoDB với quyền đầy đủ"

    ui_warning_box "⚠️ CẢNH BÁO" \
        "Chế độ này cho phép CHỈNH SỬA data N8N" \
        "Chỉ dành cho admin có kinh nghiệm" \
        "Sai thao tác có thể làm hỏng N8N!"

    if ! ui_confirm "Bạn chắc chắn muốn cài đặt với quyền đầy đủ?"; then
        return
    fi

    config_set "nocodb.access_mode" "full"
    install_nocodb_with_n8n_db
}

install_nocodb_readonly() {
    ui_section "Cài đặt NocoDB chế độ chỉ xem"

    ui_info_box "ℹ️ Chế độ an toàn" \
        "Chỉ có thể XEM data, không thể sửa" \
        "Phù hợp cho monitoring và báo cáo"

    config_set "nocodb.access_mode" "readonly"
    install_nocodb_with_n8n_db
}

install_nocodb_with_n8n_db() {
    # Check N8N installation
    if [[ ! -f "/opt/n8n/docker-compose.yml" ]]; then
        ui_status "error" "N8N chưa được cài đặt"
        return 1
    fi

    # Get configuration
    local domain port

    echo -n -e "${UI_WHITE}Nhập domain cho NocoDB: ${UI_NC}"
    read -r domain
    if ! validate_domain "$domain"; then
        return 1
    fi

    echo -n -e "${UI_WHITE}Port NocoDB ($DEFAULT_PORT): ${UI_NC}"
    read -r port
    port=${port:-$DEFAULT_PORT}
    if ! validate_port "$port"; then
        return 1
    fi

    # Check prerequisites
    if ! check_prerequisites; then
        return 1
    fi

    # Save config
    config_set "nocodb.domain" "$domain"
    config_set "nocodb.port" "$port"

    # Install
    if ! install_nocodb_components; then
        ui_status "error" "Cài đặt thất bại"
        cleanup_failed_installation
        return 1
    fi

    ui_status "success" "NocoDB cài đặt thành công!"
    show_access_info
}

check_prerequisites() {
    ui_start_spinner "Kiểm tra yêu cầu"

    local errors=0

    # Check Docker
    if ! command_exists docker; then
        ui_status "error" "Docker chưa cài đặt"
        ((errors++))
    fi

    # Check disk space
    local free_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ "$free_gb" -lt 2 ]]; then
        ui_status "error" "Cần ít nhất 2GB dung lượng (hiện có: ${free_gb}GB)"
        ((errors++))
    fi

    ui_stop_spinner
    
    # Deep cleanup old installations
    cleanup_old_nocodb_installations

    return $errors
}

cleanup_old_nocodb_installations() {
    ui_start_spinner "Dọn dẹp cài đặt cũ..."

    # Stop and remove all NocoDB related containers
    local containers=$(docker ps -a --format '{{.Names}}' | grep -E "nocodb|nocodb-postgres" || true)
    if [[ -n "$containers" ]]; then
        ui_status "info" "Dừng containers cũ..."
        echo "$containers" | xargs -r docker rm -f 2>/dev/null || true
    fi

    # Remove all NocoDB volumes
    local volumes=$(docker volume ls --format '{{.Name}}' | grep -E "nocodb" || true)
    if [[ -n "$volumes" ]]; then
        ui_status "info" "Xóa volumes cũ..."
        echo "$volumes" | xargs -r docker volume rm 2>/dev/null || true
    fi

    # Remove old directories
    local old_dirs=("/nocodb-cloud" "/opt/nocodb-db" "$NOCODB_DIR")
    for dir in "${old_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            ui_status "info" "Xóa thư mục: $dir"
            rm -rf "$dir" 2>/dev/null || true
        fi
    done

    # Clean database users
    if docker ps --format '{{.Names}}' | grep -q "n8n-postgres"; then
        ui_status "info" "Dọn dẹp database users..."
        docker exec n8n-postgres psql -U n8n -d n8n -c "
            DROP USER IF EXISTS nocodb_readonly;
            DROP USER IF EXISTS nocodb_full;
        " 2>/dev/null || true
    fi

    # Clean all nginx configs
    cleanup_nginx_configs

    # Remove htpasswd files
    rm -f /etc/nginx/.htpasswd-nocodb* 2>/dev/null || true

    ui_stop_spinner
    ui_status "success" "Dọn dẹp hoàn tất"
}

cleanup_nginx_configs() {
    local cleaned=0
    
    for nginx_conf in /etc/nginx/sites-available/*.conf; do
        if [[ -f "$nginx_conf" ]] && grep -q "location /nocodb" "$nginx_conf" 2>/dev/null; then
            ui_status "info" "Dọn dẹp NocoDB config trong: $(basename "$nginx_conf")"
            
            # Backup first
            cp "$nginx_conf" "${nginx_conf}.pre-nocodb-cleanup.$(date +%Y%m%d_%H%M%S)"
            
            # Remove nocodb location block
            sed -i '/# NocoDB subdirectory/,/^$/d' "$nginx_conf" 2>/dev/null || true
            
            ((cleaned++))
        fi
    done
    
    if [[ $cleaned -gt 0 ]]; then
        systemctl reload nginx 2>/dev/null || true
    fi
}

install_nocodb_components() {
    create_directories || return 1
    collect_credentials || return 1
    setup_database_access || return 1
    create_docker_config || return 1
    create_basic_auth || return 1
    configure_nginx || return 1
    start_services || return 1
    return 0
}

# ===== DATABASE ACCESS SETUP =====

setup_database_access() {
    ui_start_spinner "Cấu hình truy cập database"

    local access_mode=$(config_get "nocodb.access_mode")
    local n8n_db_password

    # Check if n8n-postgres is running
    if ! docker ps --format '{{.Names}}' | grep -q "n8n-postgres"; then
        ui_stop_spinner
        ui_status "error" "PostgreSQL container không chạy"
        ui_status "info" "Đang khởi động PostgreSQL..."
        
        cd /opt/n8n && docker compose up -d postgres
        sleep 5
        
        if ! docker ps --format '{{.Names}}' | grep -q "n8n-postgres"; then
            ui_status "error" "Không thể khởi động PostgreSQL"
            return 1
        fi
    fi

    # Get N8N database password
    if [[ -f "/opt/n8n/.env" ]]; then
        n8n_db_password=$(grep "POSTGRES_PASSWORD=" /opt/n8n/.env | cut -d'=' -f2)
    else
        ui_stop_spinner
        ui_status "error" "Không tìm thấy N8N database password"
        return 1
    fi

    # Create user based on access mode
    local db_user
    local sql_commands

    if [[ "$access_mode" == "readonly" ]]; then
        db_user="nocodb_readonly"
        sql_commands="
            -- Drop user if exists
            DROP USER IF EXISTS $db_user;
            
            -- Create readonly user
            CREATE USER $db_user WITH PASSWORD '$n8n_db_password';
            
            -- Grant connect permission
            GRANT CONNECT ON DATABASE n8n TO $db_user;
            
            -- Grant schema usage
            GRANT USAGE ON SCHEMA public TO $db_user;
            
            -- Grant SELECT on all tables
            GRANT SELECT ON ALL TABLES IN SCHEMA public TO $db_user;
            
            -- Grant SELECT on future tables
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO $db_user;
        "
    else
        db_user="nocodb_full"
        sql_commands="
            -- Drop user if exists
            DROP USER IF EXISTS $db_user;
            
            -- Create full access user
            CREATE USER $db_user WITH PASSWORD '$n8n_db_password';
            
            -- Grant all privileges
            GRANT ALL PRIVILEGES ON DATABASE n8n TO $db_user;
            GRANT ALL PRIVILEGES ON SCHEMA public TO $db_user;
            GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $db_user;
            GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $db_user;
            
            -- Grant for future objects
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $db_user;
            ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $db_user;
        "
    fi

    # Debug info
    ui_stop_spinner
    ui_status "info" "Đang tạo database user: $db_user"

    # Create temp SQL file to avoid escaping issues
    local temp_sql="/tmp/nocodb_setup_$.sql"
    echo "$sql_commands" > "$temp_sql"

    # Execute SQL commands with error output
    local error_log="/tmp/nocodb_db_error_$.log"
    if docker exec -i n8n-postgres psql -U n8n -d n8n < "$temp_sql" > "$error_log" 2>&1; then
        ui_status "success" "Database user $db_user đã được tạo"
        rm -f "$temp_sql" "$error_log"
    else
        ui_status "error" "Không thể tạo database user"
        echo "Chi tiết lỗi:"
        cat "$error_log"
        rm -f "$temp_sql" "$error_log"
        return 1
    fi

    config_set "nocodb.db_user" "$db_user"
    config_set "nocodb.n8n_db_password" "$n8n_db_password"
    return 0
}

# ===== CREDENTIALS COLLECTION =====

collect_credentials() {
    ui_section "Cấu hình thông tin đăng nhập"

    # Basic Auth credentials
    echo -e "${UI_CYAN}=== Basic Auth (Nginx) ===${UI_NC}"

    local auth_username
    echo -n -e "${UI_WHITE}Username (nocodb): ${UI_NC}"
    read -r auth_username
    auth_username=${auth_username:-nocodb}

    local auth_password
    while true; do
        echo -n -e "${UI_WHITE}Password (tối thiểu 8 ký tự): ${UI_NC}"
        read -s auth_password
        echo

        if [[ ${#auth_password} -ge 8 ]]; then
            break
        else
            ui_status "error" "Password phải có ít nhất 8 ký tự"
        fi
    done

    # NocoDB Admin credentials
    echo ""
    echo -e "${UI_CYAN}=== NocoDB Admin ===${UI_NC}"

    local domain=$(config_get "nocodb.domain")
    local admin_email
    echo -n -e "${UI_WHITE}Admin Email (admin@$domain): ${UI_NC}"
    read -r admin_email
    admin_email=${admin_email:-admin@$domain}

    # Validate email format
    while [[ ! "$admin_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
        ui_status "error" "Email không hợp lệ"
        echo -n -e "${UI_WHITE}Admin Email: ${UI_NC}"
        read -r admin_email
    done

    local admin_password
    echo -n -e "${UI_WHITE}Admin Password (tối thiểu 8 ký tự): ${UI_NC}"
    read -s admin_password
    echo

    while [[ ${#admin_password} -lt 8 ]]; do
        ui_status "error" "Password phải có ít nhất 8 ký tự"
        echo -n -e "${UI_WHITE}Admin Password: ${UI_NC}"
        read -s admin_password
        echo
    done

    # Save credentials
    config_set "nocodb.auth_username" "$auth_username"
    config_set "nocodb.auth_password" "$auth_password"
    config_set "nocodb.admin_email" "$admin_email"
    config_set "nocodb.admin_password" "$admin_password"

    ui_status "success" "Thông tin đăng nhập đã được lưu"
}

create_basic_auth() {
    local username=$(config_get "nocodb.auth_username")
    local password=$(config_get "nocodb.auth_password")

    # Install htpasswd if needed
    if ! command_exists htpasswd; then
        ui_run_command "Cài đặt apache2-utils" "apt-get update && apt-get install -y apache2-utils"
    fi

    # Create htpasswd file
    local htpasswd_file="/etc/nginx/.htpasswd-nocodb"
    sudo rm -f "$htpasswd_file"

    echo "$password" | sudo htpasswd -ci "$htpasswd_file" "$username"
    sudo chown www-data:www-data "$htpasswd_file"
    sudo chmod 644 "$htpasswd_file"

    ui_status "success" "Basic auth tạo thành công"
}

# ===== DOCKER CONFIGURATION =====

create_directories() {
    ui_run_command "Tạo thư mục" "
        mkdir -p $NOCODB_DIR $BACKUP_DIR
        chmod 755 $NOCODB_DIR $BACKUP_DIR
    "
}

create_docker_config() {
    ui_start_spinner "Tạo NocoDB config"

    local domain=$(config_get "nocodb.domain")
    local port=$(config_get "nocodb.port")
    local db_user=$(config_get "nocodb.db_user")
    local n8n_db_password=$(config_get "nocodb.n8n_db_password")
    local admin_email=$(config_get "nocodb.admin_email")
    local admin_password=$(config_get "nocodb.admin_password")
    local access_mode=$(config_get "nocodb.access_mode")
    local jwt_secret=$(generate_random_string 64)

    # Add readonly flag if in readonly mode
    local readonly_env=""
    if [[ "$access_mode" == "readonly" ]]; then
        readonly_env="- NC_DISABLE_AUDIT=true"
    fi

    cat >"$NOCODB_DIR/docker-compose.yml" <<EOF
services:
  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb
    restart: unless-stopped
    network_mode: host
    environment:
      - NC_DB=pg://localhost:5432?u=$db_user&p=$n8n_db_password&d=n8n
      - NC_PUBLIC_URL=https://$domain/nocodb
      - NC_ADMIN_EMAIL=$admin_email
      - NC_ADMIN_PASSWORD=$admin_password
      - NC_JWT_EXPIRES_IN=4h
      - NC_JWT_SECRET=$jwt_secret
      - NC_DISABLE_TELE=true
      - NC_SECURE_ATTACHMENTS=true
      - NC_PORT=8080
      $readonly_env
    volumes:
      - nocodb_data:/usr/app/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/v1/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

volumes:
  nocodb_data:
EOF

    ui_stop_spinner
    ui_status "success" "Docker config tạo thành công"
}

# ===== NGINX CONFIGURATION =====

configure_nginx() {
    local domain=$(config_get "nocodb.domain")
    local port=$(config_get "nocodb.port")
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"

    ui_start_spinner "Cấu hình Nginx"

    if [[ ! -f "$nginx_conf" ]]; then
        ui_stop_spinner
        ui_status "error" "Nginx config không tồn tại: $nginx_conf"
        return 1
    fi

    # Backup
    sudo cp "$nginx_conf" "${nginx_conf}.backup.$(date +%Y%m%d_%H%M%S)"

    # Check if already configured
    if sudo grep -q "location /nocodb" "$nginx_conf"; then
        ui_stop_spinner
        ui_status "warning" "NocoDB đã được cấu hình"
        return 0
    fi

    # Add NocoDB configuration
    sudo sed -i '/location ~ \/\\./i\
    # NocoDB subdirectory\
    location /nocodb/ {\
        auth_basic "N8N Database Access";\
        auth_basic_user_file /etc/nginx/.htpasswd-nocodb;\
        \
        proxy_pass http://127.0.0.1:'$port'/;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\
        proxy_set_header X-Forwarded-Proto $scheme;\
        proxy_set_header X-Script-Name /nocodb;\
        \
        proxy_http_version 1.1;\
        proxy_set_header Upgrade $http_upgrade;\
        proxy_set_header Connection "upgrade";\
        \
        proxy_redirect ~^/(.*)$ /nocodb/$1;\
        proxy_redirect / /nocodb/;\
        \
        client_max_body_size 50M;\
        proxy_read_timeout 300s;\
    }\
' "$nginx_conf"

    # Test and reload nginx
    if sudo nginx -t; then
        sudo systemctl reload nginx
        ui_stop_spinner
        ui_status "success" "Nginx cấu hình thành công"
        return 0
    else
        ui_stop_spinner
        ui_status "error" "Nginx validation thất bại"
        return 1
    fi
}

start_services() {
    ui_start_spinner "Khởi động services"

    cd "$NOCODB_DIR"
    if ! docker compose up -d; then
        ui_stop_spinner
        return 1
    fi

    # Wait for health check
    local port=$(config_get "nocodb.port")
    local max_wait=60
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if curl -s "http://localhost:$port/api/v1/health" >/dev/null 2>&1; then
            ui_stop_spinner
            ui_status "success" "Services khởi động thành công"
            return 0
        fi
        sleep 2
        ((waited += 2))
    done

    ui_stop_spinner
    ui_status "error" "Services không khởi động (timeout)"
    return 1
}

# ===== MANAGEMENT FUNCTIONS =====

get_nocodb_status() {
    if docker ps --format '{{.Names}}' | grep -q "^nocodb$"; then
        echo -e "${UI_GREEN}🟢 Running${UI_NC}"
    else
        echo -e "${UI_RED}🔴 Stopped${UI_NC}"
    fi
}

show_access_info() {
    local domain=$(config_get "nocodb.domain")
    local auth_user=$(config_get "nocodb.auth_username")
    local auth_pass=$(config_get "nocodb.auth_password")
    local admin_email=$(config_get "nocodb.admin_email")
    local admin_pass=$(config_get "nocodb.admin_password")
    local access_mode=$(config_get "nocodb.access_mode")

    ui_info_box "Thông tin truy cập NocoDB" \
        "URL: https://$domain/nocodb" \
        "Chế độ: $([ "$access_mode" == "readonly" ] && echo "CHỈ XEM" || echo "ĐẦY ĐỦ")" \
        "" \
        "Basic Auth (Nginx):" \
        "Username: $auth_user" \
        "Password: $auth_pass" \
        "" \
        "NocoDB Admin:" \
        "Email: $admin_email" \
        "Password: $admin_pass"
}

manage_access_permissions() {
    ui_section "Quản lý quyền truy cập"

    local current_mode=$(config_get "nocodb.access_mode")
    echo "Chế độ hiện tại: $([ "$current_mode" == "readonly" ] && echo "CHỈ XEM" || echo "ĐẦY ĐỦ")"
    echo ""

    echo "1) 🔄 Chuyển đổi chế độ truy cập"
    echo "2) 🔑 Đổi password Basic Auth"
    echo "3) 🔐 Đổi password Admin NocoDB"
    echo "0) ⬅️  Quay lại"
    echo ""

    echo -n -e "${UI_WHITE}Chọn [0-3]: ${UI_NC}"
    read -r choice

    case "$choice" in
    1) toggle_access_mode ;;
    2) change_basic_auth ;;
    3) change_admin_password ;;
    0) return ;;
    esac
}

toggle_access_mode() {
    local current_mode=$(config_get "nocodb.access_mode")
    local new_mode

    if [[ "$current_mode" == "readonly" ]]; then
        new_mode="full"
        ui_warning_box "⚠️ CẢNH BÁO" \
            "Chuyển sang chế độ ĐẦY ĐỦ" \
            "Cho phép CHỈNH SỬA data N8N!"

        if ! ui_confirm "Tiếp tục chuyển sang chế độ đầy đủ?"; then
            return
        fi
    else
        new_mode="readonly"
        ui_info_box "ℹ️ Thông báo" \
            "Chuyển sang chế độ CHỈ XEM" \
            "An toàn hơn cho data N8N"
    fi

    config_set "nocodb.access_mode" "$new_mode"

    # Reconfigure database access
    if setup_database_access; then
        # Restart NocoDB
        cd "$NOCODB_DIR"
        docker compose down
        create_docker_config
        docker compose up -d

        ui_status "success" "Đã chuyển sang chế độ $([ "$new_mode" == "readonly" ] && echo "CHỈ XEM" || echo "ĐẦY ĐỦ")"
    else
        ui_status "error" "Không thể chuyển đổi chế độ"
    fi
}

change_basic_auth() {
    echo -n "Username mới: "
    read -r new_username
    echo -n "Password mới: "
    read -s new_password
    echo

    if [[ ${#new_username} -lt 3 || ${#new_password} -lt 8 ]]; then
        ui_status "error" "Username >= 3, Password >= 8 ký tự"
        return
    fi

    # Update htpasswd
    echo "$new_password" | sudo htpasswd -ci /etc/nginx/.htpasswd-nocodb "$new_username"

    config_set "nocodb.auth_username" "$new_username"
    config_set "nocodb.auth_password" "$new_password"

    sudo systemctl reload nginx
    ui_status "success" "Basic Auth đã cập nhật"
}

change_admin_password() {
    echo -n "Password mới cho admin: "
    read -s new_password
    echo

    if [[ ${#new_password} -lt 8 ]]; then
        ui_status "error" "Password phải ít nhất 8 ký tự"
        return
    fi

    config_set "nocodb.admin_password" "$new_password"

    # Update container env
    cd "$NOCODB_DIR"
    docker compose down
    create_docker_config
    docker compose up -d

    ui_status "success" "Password đã cập nhật"
}

# ===== N8N TABLES GUIDE =====

show_n8n_tables_guide() {
    ui_header "Hướng dẫn N8N Database Tables"

    ui_info_box "📋 Bảng quan trọng" \
        "workflow_entity: Lưu trữ workflows" \
        "credentials_entity: Thông tin xác thực" \
        "execution_entity: Lịch sử chạy workflows" \
        "webhook_entity: Webhooks đã đăng ký"

    echo ""
    echo -e "${UI_CYAN}=== Cảnh báo khi chỉnh sửa ===${UI_NC}"
    echo "❌ KHÔNG xóa hoặc sửa trực tiếp các bảng sau:"
    echo "   - credentials_entity (mã hóa, sửa sẽ hỏng)"
    echo "   - settings (cấu hình hệ thống)"
    echo ""
    echo "⚠️  CẨN THẬN khi sửa:"
    echo "   - workflow_entity (backup trước khi sửa)"
    echo "   - execution_entity (có thể xóa log cũ)"
    echo ""
    echo "✅ AN TOÀN để xem:"
    echo "   - Tất cả các bảng ở chế độ SELECT"
    echo "   - Export data để phân tích"
    echo ""

    read -p "Nhấn Enter để tiếp tục..."
}

# ===== BACKUP FUNCTIONS =====

backup_n8n_data() {
    ui_section "Backup N8N Data"

    local backup_name="n8n_backup_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name.sql"

    ui_start_spinner "Đang backup database..."

    # Create backup
    if docker exec n8n-postgres pg_dump -U n8n n8n > "$backup_path"; then
        ui_stop_spinner
        ui_status "success" "Backup thành công: $backup_path"

        # Compress
        if gzip "$backup_path"; then
            ui_status "success" "Đã nén: ${backup_path}.gz"
        fi
    else
        ui_stop_spinner
        ui_status "error" "Backup thất bại"
        return 1
    fi

    # Show recent backups
    echo ""
    echo "📁 Backups gần đây:"
    ls -lh "$BACKUP_DIR"/*.gz 2>/dev/null | tail -5 || echo "Không có backup"
}

restart_nocodb() {
    ui_warning_box "Restart NocoDB" "Service sẽ tạm thời không khả dụng"

    if ! ui_confirm "Tiếp tục restart?"; then
        return
    fi

    ui_run_command "Restart NocoDB" "
        cd $NOCODB_DIR && docker compose restart
    "

    sleep 5
    local port=$(config_get "nocodb.port")
    if curl -s "http://localhost:$port/api/v1/health" >/dev/null 2>&1; then
        ui_status "success" "Restart thành công"
    else
        ui_status "error" "Restart thất bại"
    fi
}

show_logs() {
    echo "📝 NocoDB Logs:"
    echo "1) Application logs"
    echo "2) Error logs only"
    echo "3) Live logs (Ctrl+C để thoát)"
    echo "0) Quay lại"
    echo ""

    echo -n -e "${UI_WHITE}Chọn [0-3]: ${UI_NC}"
    read -r choice

    case "$choice" in
    1) docker logs --tail 50 nocodb ;;
    2) docker logs nocodb 2>&1 | grep -i "error\|exception" || echo "No errors" ;;
    3) docker logs -f nocodb ;;
    0) return ;;
    esac
}

# ===== CLEANUP FUNCTIONS =====

cleanup_failed_installation() {
    ui_status "warning" "Dọn dẹp cài đặt thất bại..."

    # Stop containers
    if [[ -f "$NOCODB_DIR/docker-compose.yml" ]]; then
        cd "$NOCODB_DIR" && docker compose down -v 2>/dev/null || true
    fi

    # Remove directories
    rm -rf "$NOCODB_DIR" 2>/dev/null || true

    # Restore nginx if needed
    local domain=$(config_get "nocodb.domain" "")
    if [[ -n "$domain" ]]; then
        local nginx_conf="/etc/nginx/sites-available/${domain}.conf"
        local backup=$(ls "${nginx_conf}.backup."* 2>/dev/null | tail -1)
        if [[ -f "$backup" ]]; then
            cp "$backup" "$nginx_conf"
            systemctl reload nginx 2>/dev/null || true
        fi
    fi

    rm -f /etc/nginx/.htpasswd-nocodb 2>/dev/null || true
}

uninstall_nocodb() {
    ui_warning_box "Gỡ cài đặt NocoDB" \
        "⚠️  Sẽ xóa toàn bộ cấu hình NocoDB" \
        "Data N8N sẽ KHÔNG bị ảnh hưởng"

    echo -n "Gõ 'DELETE' để xác nhận: "
    read -r confirmation

    if [[ "$confirmation" != "DELETE" ]]; then
        ui_status "info" "Đã hủy"
        return
    fi

    # Stop services
    if [[ -f "$NOCODB_DIR/docker-compose.yml" ]]; then
        ui_run_command "Dừng services" "
            cd $NOCODB_DIR && docker compose down -v
        "
    fi

    # Deep cleanup
    ui_run_command "Xóa containers và volumes" "
        # Remove any NocoDB related containers
        docker ps -a --format '{{.Names}}' | grep -E 'nocodb' | xargs -r docker rm -f 2>/dev/null || true
        
        # Remove all NocoDB volumes
        docker volume ls --format '{{.Name}}' | grep -E 'nocodb' | xargs -r docker volume rm 2>/dev/null || true
    "

    # Remove directories
    ui_run_command "Xóa thư mục" "
        rm -rf $NOCODB_DIR /opt/nocodb-db /nocodb-cloud 2>/dev/null || true
    "

    # Drop database users
    if docker ps --format '{{.Names}}' | grep -q "n8n-postgres"; then
        ui_run_command "Xóa database users" "
            docker exec n8n-postgres psql -U n8n -d n8n -c '
                DROP USER IF EXISTS nocodb_readonly CASCADE;
                DROP USER IF EXISTS nocodb_full CASCADE;
            ' 2>/dev/null || true
        "
    fi

    # Clean all nginx configs
    ui_run_command "Dọn dẹp Nginx configs" "
        # Find and clean all nginx configs with nocodb
        for conf in /etc/nginx/sites-available/*.conf; do
            if grep -q 'location /nocodb' \"\$conf\" 2>/dev/null; then
                # Backup
                cp \"\$conf\" \"\${conf}.pre-uninstall.\$(date +%Y%m%d_%H%M%S)\"
                # Remove nocodb block
                sed -i '/# NocoDB subdirectory/,/^$/d' \"\$conf\"
            fi
        done
        
        # Remove all htpasswd files
        rm -f /etc/nginx/.htpasswd-nocodb*
        
        # Reload nginx
        systemctl reload nginx || true
    "

    # Clean backup directory
    if [[ -d "$BACKUP_DIR" ]]; then
        ui_run_command "Xóa backups" "rm -rf $BACKUP_DIR"
    fi

    # Clear all config
    ui_run_command "Xóa cấu hình" "
        # Clear all nocodb related configs
        for key in \$(grep '^nocodb\\.' ~/.config/datalonline-n8n/settings.conf 2>/dev/null | cut -d= -f1); do
            sed -i \"/^\$key=/d\" ~/.config/datalonline-n8n/settings.conf
        done
    "

    ui_status "success" "NocoDB đã được gỡ hoàn toàn"
}

# Export main function
export -f nocodb_main_menu