#!/bin/bash

# DataOnline N8N Manager - NocoDB Setup & Docker Integration
# Phiên bản: 1.0.3 - Custom Domain Support

set -euo pipefail

# Global variables for database choice
NOCODB_DATABASE_MODE=""  # "shared" or "separate"
NOCODB_DB_NAME=""
NOCODB_DB_PASSWORD=""
NOCODB_DOMAIN=""  # Custom domain from user

# ===== DOMAIN CONFIGURATION =====

ask_nocodb_domain() {
    ui_section "Cấu hình Domain cho NocoDB"
    
    local main_domain=$(config_get "n8n.domain" "")
    
    echo "📊 **Lựa chọn domain cho NocoDB:**"
    echo ""
    echo "1) 🔗 Sử dụng subdomain tự động: db.$main_domain"
    echo "2) 🏠 Nhập domain riêng (VD: nocodb.company.com)"
    echo "3) 📱 Chỉ sử dụng IP:Port (không domain)"
    echo ""
    
    while true; do
        read -p "Chọn [1-3]: " domain_choice
        
        case "$domain_choice" in
        1)
            if [[ -n "$main_domain" ]]; then
                NOCODB_DOMAIN="db.$main_domain"
                ui_status "success" "Sử dụng subdomain: $NOCODB_DOMAIN"
                break
            else
                ui_status "error" "Chưa có domain chính N8N"
                echo -n -e "${UI_WHITE}Nhập domain chính N8N: ${UI_NC}"
                read -r main_domain
                if [[ -n "$main_domain" ]]; then
                    config_set "n8n.domain" "$main_domain"
                    NOCODB_DOMAIN="db.$main_domain"
                    ui_status "success" "Sử dụng subdomain: $NOCODB_DOMAIN"
                    break
                fi
            fi
            ;;
        2)
            echo -n -e "${UI_WHITE}Nhập domain cho NocoDB: ${UI_NC}"
            read -r custom_domain
            
            if [[ -z "$custom_domain" ]]; then
                ui_status "error" "Domain không được để trống"
                continue
            fi
            
            if ui_validate_domain "$custom_domain"; then
                NOCODB_DOMAIN="$custom_domain"
                ui_status "success" "Sử dụng domain: $NOCODB_DOMAIN"
                break
            else
                ui_status "error" "Domain không hợp lệ"
            fi
            ;;
        3)
            NOCODB_DOMAIN=""
            ui_status "info" "Sử dụng IP:Port (không cần domain)"
            break
            ;;
        *)
            ui_status "error" "Lựa chọn không hợp lệ"
            ;;
        esac
    done
    
    return 0
}

# ===== DATABASE PREFERENCE SELECTION =====

ask_database_preference() {
    ui_section "Lựa chọn Database cho NocoDB"
    
    echo "📊 **Lựa chọn database:**"
    echo ""
    echo "1) 🔗 Dùng chung database với N8N (đơn giản)"
    echo "   ✅ Setup nhanh, ít tài nguyên"
    echo "   ⚠️  Rủi ro: performance và security chung"
    echo ""
    echo "2) 🏠 Database riêng cho NocoDB (an toàn)"
    echo "   ✅ Độc lập, an toàn hơn"
    echo "   ⚠️  Phức tạp hơn, nhiều tài nguyên"
    echo ""
    
    while true; do
        read -p "Chọn [1-2]: " db_choice
        
        case "$db_choice" in
        1)
            NOCODB_DATABASE_MODE="shared"
            NOCODB_DB_NAME="n8n"
            ui_status "info" "Sử dụng database chung: n8n"
            break
            ;;
        2)
            NOCODB_DATABASE_MODE="separate"
            NOCODB_DB_NAME="nocodb"
            ui_status "info" "Sử dụng database riêng: nocodb"
            break
            ;;
        *)
            ui_status "error" "Lựa chọn không hợp lệ"
            ;;
        esac
    done
    
    return 0
}

# ===== DOCKER INTEGRATION FUNCTIONS =====

setup_nocodb_integration() {
    ui_section "Cài đặt NocoDB Integration"

    # Ask domain preference first
    if ! ask_nocodb_domain; then
        return 1
    fi

    # Ask database preference
    if ! ask_database_preference; then
        return 1
    fi
    
    if ! generate_nocodb_secrets; then
        return 1
    fi
    
    if ! backup_docker_compose; then
        return 1
    fi
    
    if ! update_docker_compose_for_nocodb; then
        return 1
    fi
    
    if ! start_nocodb_service; then
        return 1
    fi
    
    if ! wait_for_nocodb_ready; then
        return 1
    fi
    
    if ! configure_nocodb_database; then
        return 1
    fi
    
    # SSL setup option (only if domain is configured)
    if [[ -n "$NOCODB_DOMAIN" ]]; then
        echo ""
        echo -n -e "${UI_YELLOW}Cấu hình SSL cho $NOCODB_DOMAIN? [Y/n]: ${UI_NC}"
        read -r setup_ssl
        if [[ ! "$setup_ssl" =~ ^[Nn]$ ]]; then
            setup_nocodb_ssl
        fi
    fi
    
    ui_status "success" "NocoDB integration hoàn tất!"
    
    # Show access info
    local nocodb_url=$(get_nocodb_url)
    ui_info_box "Truy cập NocoDB" \
        "URL: $nocodb_url" \
        "Email: $(config_get "nocodb.admin_email")" \
        "Password: $(get_nocodb_admin_password)" \
        "Database: $NOCODB_DATABASE_MODE ($NOCODB_DB_NAME)" \
        "$([ -n "$NOCODB_DOMAIN" ] && echo "Domain: $NOCODB_DOMAIN")"
    
    # Show N8N database connection info for both modes
    local n8n_postgres_password=$(grep "POSTGRES_PASSWORD=" "$N8N_COMPOSE_DIR/.env" | cut -d'=' -f2)
    ui_info_box "Kết nối N8N Database trong NocoDB" \
        "Host: postgres (hoặc IP server)" \
        "Port: 5432" \
        "Database: n8n" \
        "User: n8n" \
        "Password: $n8n_postgres_password" \
        "" \
        "💡 Sử dụng thông tin này để kết nối N8N data trong NocoDB"
    
    return 0
}

get_nocodb_url() {
    if [[ -n "$NOCODB_DOMAIN" ]]; then
        # Use custom domain
        local ssl_enabled=$(config_get "nocodb.ssl_enabled" "false")
        if [[ "$ssl_enabled" == "true" ]]; then
            echo "https://$NOCODB_DOMAIN"
        else
            echo "http://$NOCODB_DOMAIN"
        fi
    else
        # Use IP:Port
        local public_ip=$(get_public_ip || echo "localhost")
        echo "http://$public_ip:8080"
    fi
}

# ===== SECRETS GENERATION =====

generate_nocodb_secrets() {
    ui_start_spinner "Tạo security secrets"
    
    local jwt_secret=$(generate_random_string 64)
    local admin_password=$(generate_random_string 16)
    
    # Stop spinner to get user input
    ui_stop_spinner
    
    # Get admin email from user with validation
    ui_section "Cấu hình Admin NocoDB"
    local admin_email=""
    
    while true; do
        echo -n -e "${UI_WHITE}Nhập email admin cho NocoDB: ${UI_NC}"
        read -r admin_email
        
        # Validate email format
        if [[ -z "$admin_email" ]]; then
            ui_status "error" "Email không được để trống"
            continue
        fi
        
        if [[ "$admin_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            ui_status "success" "Email hợp lệ: $admin_email"
            break
        else
            ui_status "error" "Email không hợp lệ. Vui lòng nhập lại (VD: admin@company.com)"
        fi
    done
    
    ui_start_spinner "Lưu cấu hình"
    
    # Generate database password for separate mode
    if [[ "$NOCODB_DATABASE_MODE" == "separate" ]]; then
        NOCODB_DB_PASSWORD=$(generate_random_string 32)
    else
        # Use N8N's postgres password for shared mode
        NOCODB_DB_PASSWORD=$(grep "POSTGRES_PASSWORD=" "$N8N_COMPOSE_DIR/.env" | cut -d'=' -f2)
    fi
    
    # Check if .env exists
    if [[ ! -f "$N8N_COMPOSE_DIR/.env" ]]; then
        ui_stop_spinner
        ui_status "error" "File .env không tồn tại tại $N8N_COMPOSE_DIR"
        return 1
    fi
    
    # Determine public URL based on domain choice
    local public_url
    if [[ -n "$NOCODB_DOMAIN" ]]; then
        public_url="https://$NOCODB_DOMAIN"
    else
        local public_ip=$(get_public_ip || echo "localhost")
        public_url="http://$public_ip:8080"
    fi
    
    # Add NocoDB config to .env if not exists
    if ! grep -q "NOCODB_JWT_SECRET" "$N8N_COMPOSE_DIR/.env"; then
        cat >> "$N8N_COMPOSE_DIR/.env" << EOF

# NocoDB Configuration - Added by DataOnline Manager
NOCODB_DATABASE_MODE=$NOCODB_DATABASE_MODE
NOCODB_DOMAIN=$NOCODB_DOMAIN
NOCODB_JWT_SECRET=$jwt_secret
NOCODB_ADMIN_EMAIL=$admin_email
NOCODB_ADMIN_PASSWORD=$admin_password
NOCODB_PUBLIC_URL=$public_url

# NocoDB Database Configuration
NC_DB_TYPE=pg
NC_DB_HOST=postgres
NC_DB_PORT=5432
NC_DB_USER=nocodb
NC_DB_PASSWORD=$NOCODB_DB_PASSWORD
NC_DB_DATABASE=$NOCODB_DB_NAME
NC_DB_SSL=false
NC_DB_MIGRATE=true
NC_DB_MIGRATE_LOCK=true
NC_MIN_DB_POOL_SIZE=1
NC_MAX_DB_POOL_SIZE=10
EOF
    fi
    
    # Save admin password to separate file for easy access
    echo "$admin_password" > "$N8N_COMPOSE_DIR/.nocodb-admin-password"
    chmod 600 "$N8N_COMPOSE_DIR/.nocodb-admin-password"
    
    # Update config
    config_set "nocodb.admin_email" "$admin_email"
    config_set "nocodb.domain" "$NOCODB_DOMAIN"
    config_set "nocodb.database_mode" "$NOCODB_DATABASE_MODE"
    config_set "nocodb.database_name" "$NOCODB_DB_NAME"
    config_set "nocodb.installed" "true"
    config_set "nocodb.installed_date" "$(date -Iseconds)"
    
    ui_stop_spinner
    ui_status "success" "Secrets đã được tạo (mode: $NOCODB_DATABASE_MODE)"
    ui_info_box "Thông tin đăng nhập" \
        "Email: $admin_email" \
        "Password: $admin_password" \
        "Mode: $NOCODB_DATABASE_MODE" \
        "$([ -n "$NOCODB_DOMAIN" ] && echo "Domain: $NOCODB_DOMAIN")" \
        "Public URL: $public_url"
    
    return 0
}

# ===== DOCKER COMPOSE MANAGEMENT =====

backup_docker_compose() {
    ui_start_spinner "Backup docker-compose hiện tại"
    
    local backup_dir="$N8N_COMPOSE_DIR/backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # Create backup directory
    if ! mkdir -p "$backup_dir"; then
        ui_stop_spinner
        ui_status "error" "Không thể tạo thư mục backup"
        return 1
    fi
    
    # Backup files
    cp "$N8N_COMPOSE_DIR/docker-compose.yml" "$backup_dir/docker-compose.yml.backup_$timestamp"
    cp "$N8N_COMPOSE_DIR/.env" "$backup_dir/.env.backup_$timestamp"
    
    ui_stop_spinner
    ui_status "success" "Đã backup tại: $backup_dir"
    return 0
}

update_docker_compose_for_nocodb() {
    ui_start_spinner "Cập nhật docker-compose.yml"
    
    local compose_file="$N8N_COMPOSE_DIR/docker-compose.yml"
    
    # Check if NocoDB already exists
    if grep -q "nocodb" "$compose_file"; then
        ui_stop_spinner
        ui_status "warning" "NocoDB đã tồn tại trong docker-compose"
        return 0
    fi
    
    # Create nocodb config directory
    mkdir -p "$N8N_COMPOSE_DIR/nocodb-config"
    
    # Insert NocoDB service before volumes section
    if add_nocodb_service_to_compose "$compose_file"; then
        # Add nocodb volume if not exists
        add_nocodb_volume "$compose_file"
        ui_stop_spinner
        ui_status "success" "docker-compose.yml đã được cập nhật (mode: $NOCODB_DATABASE_MODE)"
        return 0
    else
        ui_stop_spinner
        ui_status "error" "Cập nhật docker-compose.yml thất bại"
        return 1
    fi
}

# Updated: Support both shared and separate database modes
add_nocodb_service_to_compose() {
    local compose_file="$1"
    local temp_file="/tmp/docker-compose-nocodb-$(date +%s).yml"
    
    # Create backup
    cp "$compose_file" "${compose_file}.backup.$(date +%s)"
    
    # Source environment variables
    set -a  # automatically export all variables
    source /opt/n8n/.env
    set +a
    
    # Create compose template based on database mode
    if [[ "$NOCODB_DATABASE_MODE" == "separate" ]]; then
        create_separate_database_compose "$temp_file"
    else
        create_shared_database_compose "$temp_file"
    fi
    
    # Validate and replace
    if docker compose -f "$temp_file" config >/dev/null 2>&1; then
        mv "$temp_file" "$compose_file"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Create compose for separate database mode
create_separate_database_compose() {
    local temp_file="$1"
    
    envsubst < /dev/stdin > "$temp_file" << 'EOF'
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_DOMAIN:-localhost}
      - N8N_PORT=5678
      - N8N_PROTOCOL=${N8N_PROTOCOL:-https}
      - NODE_ENV=production
      - WEBHOOK_URL=${N8N_WEBHOOK_URL}
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=regular
      - EXECUTIONS_PROCESS=main
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=changeme
      - N8N_METRICS=false
    ports:
      - "5678:5678"
    volumes:
      - n8n_data:/home/node/.n8n
      - ./backups:/backups
    networks:
      - n8n-network

  nocodb:
    image: nocodb/nocodb:latest
    container_name: n8n-nocodb
    restart: unless-stopped
    environment:
      # Database connection using separate variables
      - NC_DB_TYPE=pg
      - NC_DB_HOST=postgres
      - NC_DB_PORT=5432
      - NC_DB_USER=nocodb
      - NC_DB_PASSWORD=${NOCODB_DB_PASSWORD}
      - NC_DB_DATABASE=nocodb
      - NC_DB_SSL=false
      
      # Database migration settings
      - NC_DB_MIGRATE=true
      - NC_DB_MIGRATE_LOCK=true
      - NC_MIN_DB_POOL_SIZE=1
      - NC_MAX_DB_POOL_SIZE=10
      
      # NocoDB configuration
      - NC_PUBLIC_URL=${NOCODB_PUBLIC_URL}
      - NC_AUTH_JWT_SECRET=${NOCODB_JWT_SECRET}
      - NC_ADMIN_EMAIL=${NOCODB_ADMIN_EMAIL}
      - NC_ADMIN_PASSWORD=${NOCODB_ADMIN_PASSWORD}
      - NC_DISABLE_TELE=true
      - NC_DASHBOARD_URL=/dashboard
      
      # Additional configuration
      - NC_TOOL_DIR=/tmp/nc-tool
      - NC_LOG_LEVEL=info
      - NODE_ENV=production
      
    ports:
      - "8080:8080"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - nocodb_data:/usr/app/data
      - ./nocodb-config:/usr/app/config
    networks:
      - n8n-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/v1/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

volumes:
  postgres_data:
    driver: local
  n8n_data:
    driver: local
  nocodb_data:
    driver: local

networks:
  n8n-network:
    driver: bridge
EOF
}

# Create compose for shared database mode
create_shared_database_compose() {
    local temp_file="$1"
    
    envsubst < /dev/stdin > "$temp_file" << 'EOF'
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_DOMAIN:-localhost}
      - N8N_PORT=5678
      - N8N_PROTOCOL=${N8N_PROTOCOL:-https}
      - NODE_ENV=production
      - WEBHOOK_URL=${N8N_WEBHOOK_URL}
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=regular
      - EXECUTIONS_PROCESS=main
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=changeme
      - N8N_METRICS=false
    ports:
      - "5678:5678"
    volumes:
      - n8n_data:/home/node/.n8n
      - ./backups:/backups
    networks:
      - n8n-network

  nocodb:
    image: nocodb/nocodb:latest
    container_name: n8n-nocodb
    restart: unless-stopped
    environment:
      # Database connection using shared N8N database
      - NC_DB_TYPE=pg
      - NC_DB_HOST=postgres
      - NC_DB_PORT=5432
      - NC_DB_USER=n8n
      - NC_DB_PASSWORD=${POSTGRES_PASSWORD}
      - NC_DB_DATABASE=n8n
      - NC_DB_SSL=false
      
      # Database migration settings
      - NC_DB_MIGRATE=true
      - NC_DB_MIGRATE_LOCK=true
      - NC_MIN_DB_POOL_SIZE=1
      - NC_MAX_DB_POOL_SIZE=10
      
      # NocoDB configuration
      - NC_PUBLIC_URL=${NOCODB_PUBLIC_URL}
      - NC_AUTH_JWT_SECRET=${NOCODB_JWT_SECRET}
      - NC_ADMIN_EMAIL=${NOCODB_ADMIN_EMAIL}
      - NC_ADMIN_PASSWORD=${NOCODB_ADMIN_PASSWORD}
      - NC_DISABLE_TELE=true
      - NC_DASHBOARD_URL=/dashboard
      
      # Additional configuration
      - NC_TOOL_DIR=/tmp/nc-tool
      - NC_LOG_LEVEL=info
      - NODE_ENV=production
      
    ports:
      - "8080:8080"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - nocodb_data:/usr/app/data
      - ./nocodb-config:/usr/app/config
    networks:
      - n8n-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/v1/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

volumes:
  postgres_data:
    driver: local
  n8n_data:
    driver: local
  nocodb_data:
    driver: local

networks:
  n8n-network:
    driver: bridge
EOF
}

add_nocodb_volume() {
    local compose_file="$1"
    
    # Add nocodb_data volume if not exists
    if ! grep -q "nocodb_data:" "$compose_file"; then
        # Find volumes section and add nocodb_data
        if grep -q "^volumes:" "$compose_file"; then
            # Volumes section exists, add nocodb_data
            sed -i '/^volumes:/a\  nocodb_data:\n    driver: local' "$compose_file"
        else
            # No volumes section, add it
            echo "" >> "$compose_file"
            echo "volumes:" >> "$compose_file"
            echo "  nocodb_data:" >> "$compose_file"
            echo "    driver: local" >> "$compose_file"
        fi
    fi
}

# ===== SERVICE MANAGEMENT =====

start_nocodb_service() {
    ui_start_spinner "Khởi động NocoDB service"
    
    cd "$N8N_COMPOSE_DIR" || return 1
    
    # Create separate database if needed
    if [[ "$NOCODB_DATABASE_MODE" == "separate" ]]; then
        create_separate_nocodb_database
    fi
    
    # Pull NocoDB image first
    if ! docker compose pull nocodb 2>/dev/null; then
        ui_stop_spinner
        ui_status "error" "Không thể pull NocoDB image"
        return 1
    fi
    
    # Start NocoDB service
    if ! docker compose up -d nocodb 2>/dev/null; then
        ui_stop_spinner
        ui_status "error" "Không thể khởi động NocoDB"
        return 1
    fi
    
    ui_stop_spinner
    ui_status "success" "NocoDB service đã khởi động"
    return 0
}

# Create separate database for NocoDB
create_separate_nocodb_database() {
    ui_status "info" "Tạo database riêng cho NocoDB..."
    
    # Wait for PostgreSQL to be ready
    local max_wait=30
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        if docker exec n8n-postgres pg_isready -U n8n >/dev/null 2>&1; then
            break
        fi
        sleep 1
        ((waited++))
    done
    
    # Create nocodb user and database
    docker exec n8n-postgres psql -U n8n -c "
        CREATE USER nocodb WITH PASSWORD '$NOCODB_DB_PASSWORD';
        CREATE DATABASE nocodb OWNER nocodb;
        GRANT ALL PRIVILEGES ON DATABASE nocodb TO nocodb;
    " >/dev/null 2>&1 || {
        # Database/user might already exist, which is fine
        ui_status "info" "Database/user nocodb đã tồn tại hoặc đã được tạo"
    }
    
    ui_status "success" "Database riêng cho NocoDB đã sẵn sàng"
}

# Enhanced wait function with database mode awareness
wait_for_nocodb_ready() {
    ui_start_spinner "Chờ NocoDB sẵn sàng"
    
    local max_wait=300  # 5 minutes for initialization
    local waited=0
    local health_url="http://localhost:8080/api/v1/health"
    local check_interval=10
    
    while [[ $waited -lt $max_wait ]]; do
        # Check if container is running
        if ! docker ps --format '{{.Names}}' | grep -q "^n8n-nocodb$"; then
            ui_stop_spinner
            ui_status "error" "NocoDB container stopped unexpectedly"
            
            # Show recent logs
            echo "Recent logs:"
            docker logs --tail 10 n8n-nocodb 2>&1 | head -10
            return 1
        fi
        
        # Check API health
        if curl -s -f "$health_url" >/dev/null 2>&1; then
            ui_stop_spinner
            ui_status "success" "NocoDB đã sẵn sàng (database: $NOCODB_DATABASE_MODE)"
            return 0
        fi
        
        # Check for database connection errors in logs
        if docker logs --tail 5 n8n-nocodb 2>&1 | grep -i "database.*error\|connection.*failed\|Meta database configuration"; then
            ui_stop_spinner
            ui_status "error" "NocoDB database connection failed"
            echo "Recent error logs:"
            docker logs --tail 10 n8n-nocodb 2>&1 | grep -i "error\|exception" | head -5
            return 1
        fi
        
        sleep $check_interval
        ((waited += check_interval))
    done
    
    ui_stop_spinner
    ui_status "error" "Timeout chờ NocoDB khởi động"
    
    # Show debug information
    echo "Debug information:"
    echo "Container status: $(docker inspect n8n-nocodb --format='{{.State.Status}}' 2>/dev/null || echo 'unknown')"
    echo "Database mode: $NOCODB_DATABASE_MODE"
    echo "Domain: ${NOCODB_DOMAIN:-'IP:Port'}"
    echo "Recent logs:"
    docker logs --tail 10 n8n-nocodb 2>&1 | head -10
    
    return 1
}

configure_nocodb_database() {
    ui_start_spinner "Cấu hình kết nối database"
    
    # NocoDB will auto-connect via environment variables
    # Just verify the connection works
    local api_url="http://localhost:8080/api/v1/db/meta/projects"
    
    # Wait a bit for database initialization
    sleep 5
    
    if curl -s "$api_url" >/dev/null 2>&1; then
        ui_stop_spinner
        ui_status "success" "Database connection OK (mode: $NOCODB_DATABASE_MODE)"
        return 0
    else
        ui_stop_spinner
        ui_status "error" "Database connection failed"
        return 1
    fi
}

# ===== SSL SUBDOMAIN SETUP (UPDATED) =====

setup_nocodb_ssl() {
    if [[ -z "$NOCODB_DOMAIN" ]]; then
        ui_status "error" "Chưa cấu hình domain cho NocoDB"
        return 1
    fi
    
    ui_info_box "SSL Setup cho NocoDB" \
        "Domain: $NOCODB_DOMAIN" \
        "Port: 8080 → 443" \
        "Certificate: Let's Encrypt"
    
    if ! ui_confirm "Setup SSL cho $NOCODB_DOMAIN?"; then
        return 0
    fi
    
    # Create nginx config
    create_nocodb_nginx_config "$NOCODB_DOMAIN"
    
    # Get SSL certificate
    obtain_nocodb_ssl_certificate "$NOCODB_DOMAIN"
    
    # Update NocoDB config
    update_nocodb_ssl_config "$NOCODB_DOMAIN"
}

create_nocodb_nginx_config() {
    local domain="$1"
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"
    
    ui_start_spinner "Tạo Nginx config cho $domain"
    
    cat > "$nginx_conf" << EOF
server {
    listen 80;
    server_name $domain;

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
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 100M;
    
    access_log /var/log/nginx/$domain.access.log;
    error_log /var/log/nginx/$domain.error.log;

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
    ln -sf "$nginx_conf" /etc/nginx/sites-enabled/
    
    ui_stop_spinner
    ui_status "success" "Nginx config tạo thành công"
}

obtain_nocodb_ssl_certificate() {
    local domain="$1"
    local email="admin@$(echo "$domain" | cut -d'.' -f2-)"
    
    # Ensure webroot exists
    mkdir -p /var/www/html/.well-known/acme-challenge
    chown -R www-data:www-data /var/www/html
    
    # Test nginx config
    if ! nginx -t; then
        ui_status "error" "Nginx config có lỗi"
        return 1
    fi
    
    # Reload nginx
    systemctl reload nginx
    
    ui_start_spinner "Lấy SSL certificate cho $domain"
    
    if certbot certonly --webroot \
        -w /var/www/html \
        -d "$domain" \
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
    
    # Download SSL options if needed
    if [[ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]]; then
        curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
            -o /etc/letsencrypt/options-ssl-nginx.conf
    fi
    
    if [[ ! -f /etc/letsencrypt/ssl-dhparams.pem ]]; then
        openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
    fi
    
    # Reload nginx with SSL
    systemctl reload nginx
}

update_nocodb_ssl_config() {
    local domain="$1"
    
    ui_start_spinner "Cập nhật NocoDB config"
    
    # Update .env
    sed -i "s|NOCODB_PUBLIC_URL=.*|NOCODB_PUBLIC_URL=https://$domain|" "$N8N_COMPOSE_DIR/.env"
    
    # Save to manager config
    config_set "nocodb.domain" "$domain"
    config_set "nocodb.ssl_enabled" "true"
    
    # Restart NocoDB
    cd "$N8N_COMPOSE_DIR"
    docker compose restart nocodb
    
    ui_stop_spinner
    ui_status "success" "NocoDB config cập nhật thành công"
}

# ===== REMOVAL FUNCTIONS =====

remove_nocodb_integration() {
    ui_section "Gỡ bỏ NocoDB integration"
    
    local database_mode=$(config_get "nocodb.database_mode" "shared")
    
    ui_info_box "Thông tin gỡ bỏ" \
        "Database mode: $database_mode" \
        "$([ "$database_mode" == "separate" ] && echo "Database riêng sẽ được xóa")" \
        "$([ "$database_mode" == "shared" ] && echo "Chỉ xóa NocoDB tables trong database N8N")"
    
    # Stop and remove NocoDB container
    if ! stop_and_remove_nocodb; then
        ui_status "error" "Không thể dừng NocoDB container"
        return 1
    fi
    
    # Remove from docker-compose
    if ! remove_nocodb_from_compose; then
        ui_status "error" "Không thể xóa NocoDB khỏi docker-compose"
        return 1
    fi
    
    # Handle database cleanup based on mode
    if [[ "$database_mode" == "separate" ]]; then
        echo -n -e "${UI_YELLOW}Xóa database riêng của NocoDB? [y/N]: ${UI_NC}"
        read -r remove_db
        if [[ "$remove_db" =~ ^[Yy]$ ]]; then
            remove_separate_nocodb_database
        fi
    else
        echo -n -e "${UI_YELLOW}Xóa NocoDB tables trong database N8N? [y/N]: ${UI_NC}"
        read -r remove_tables
        if [[ "$remove_tables" =~ ^[Yy]$ ]]; then
            remove_nocodb_tables_from_shared_db
        fi
    fi
    
    # Clean up volumes (optional)
    echo -n -e "${UI_YELLOW}Xóa NocoDB volumes? [y/N]: ${UI_NC}"
    read -r remove_data
    if [[ "$remove_data" =~ ^[Yy]$ ]]; then
        remove_nocodb_data
    fi
    
    # Clean up config
    clean_nocodb_config
    
    ui_status "success" "NocoDB đã được gỡ bỏ hoàn toàn"
    return 0
}

remove_separate_nocodb_database() {
    ui_start_spinner "Xóa database riêng của NocoDB"
    
    docker exec n8n-postgres psql -U n8n -c "
        DROP DATABASE IF EXISTS nocodb;
        DROP USER IF EXISTS nocodb;
    " >/dev/null 2>&1 || true
    
    ui_stop_spinner
    ui_status "success" "Database riêng đã được xóa"
}

remove_nocodb_tables_from_shared_db() {
    ui_start_spinner "Xóa NocoDB tables từ database N8N"
    
    # Get list of NocoDB tables (they usually start with 'nc_')
    local nocodb_tables=$(docker exec n8n-postgres psql -U n8n n8n -t -c "
        SELECT tablename FROM pg_tables 
        WHERE schemaname = 'public' AND tablename LIKE 'nc_%';
    " | tr -d ' ')
    
    if [[ -n "$nocodb_tables" ]]; then
        for table in $nocodb_tables; do
            docker exec n8n-postgres psql -U n8n n8n -c "DROP TABLE IF EXISTS \"$table\" CASCADE;" >/dev/null 2>&1 || true
        done
        ui_stop_spinner
        ui_status "success" "NocoDB tables đã được xóa"
    else
        ui_stop_spinner
        ui_status "info" "Không tìm thấy NocoDB tables"
    fi
}

stop_and_remove_nocodb() {
    ui_start_spinner "Dừng và xóa NocoDB container"
    
    cd "$N8N_COMPOSE_DIR" || return 1
    
    # Stop NocoDB
    docker compose stop nocodb 2>/dev/null || true
    
    # Remove NocoDB container
    docker compose rm -f nocodb 2>/dev/null || true
    
    ui_stop_spinner
    ui_status "success" "Container đã được xóa"
    return 0
}

remove_nocodb_from_compose() {
    ui_start_spinner "Xóa NocoDB khỏi docker-compose"
    
    local compose_file="$N8N_COMPOSE_DIR/docker-compose.yml"
    local temp_file="/tmp/docker-compose-clean.yml"
    
    # Remove NocoDB service section
    awk '
        /^  nocodb:/ { skip=1; next }
        /^  [a-zA-Z]/ && skip { skip=0 }
        /^[a-zA-Z]/ && skip { skip=0; print; next }
        !skip { print }
    ' "$compose_file" > "$temp_file"
    
    # Remove nocodb volume
    sed -i '/nocodb_data:/,+1d' "$temp_file"
    
    # Validate and replace
    if docker compose -f "$temp_file" config >/dev/null 2>&1; then
        mv "$temp_file" "$compose_file"
        ui_stop_spinner
        ui_status "success" "Đã xóa khỏi docker-compose"
        return 0
    else
        rm -f "$temp_file"
        ui_stop_spinner
        ui_status "error" "Lỗi xóa khỏi docker-compose"
        return 1
    fi
}

remove_nocodb_data() {
    ui_start_spinner "Xóa NocoDB volumes"
    
    # Remove volume
    docker volume rm n8n_nocodb_data 2>/dev/null || true
    
    # Remove config files
    rm -rf "$N8N_COMPOSE_DIR/nocodb-config" 2>/dev/null || true
    rm -f "$N8N_COMPOSE_DIR/.nocodb-admin-password" 2>/dev/null || true
    
    ui_stop_spinner
    ui_status "success" "Volumes đã được xóa"
}

clean_nocodb_config() {
    # Remove from .env file
    if [[ -f "$N8N_COMPOSE_DIR/.env" ]]; then
        sed -i '/# NocoDB Configuration/,/^$/d' "$N8N_COMPOSE_DIR/.env"
    fi
    
    # Remove from manager config
    config_set "nocodb.installed" "false"
    config_set "nocodb.admin_email" ""
    config_set "nocodb.domain" ""
    config_set "nocodb.database_mode" ""
    config_set "nocodb.database_name" ""
    
    ui_status "success" "Cấu hình đã được dọn dẹp"
}

# ===== MAINTENANCE FUNCTIONS =====

nocodb_maintenance() {
    ui_section "Bảo trì NocoDB"
    
    local database_mode=$(config_get "nocodb.database_mode" "shared")
    local nocodb_domain=$(config_get "nocodb.domain" "")
    
    echo "Database mode: $database_mode"
    if [[ -n "$nocodb_domain" ]]; then
        echo "Domain: $nocodb_domain"
    fi
    echo ""
    
    echo "1) 🔄 Restart NocoDB"
    echo "2) 🔄 Update NocoDB image"
    echo "3) 🧹 Dọn dẹp logs"
    echo "4) 📊 Kiểm tra tài nguyên"
    echo "5) 🔒 Reset admin password"
    echo "0) ⬅️  Quay lại"
    echo ""
    
    read -p "Chọn [0-5]: " maintenance_choice
    
    case "$maintenance_choice" in
    1) restart_nocodb ;;
    2) update_nocodb_image ;;
    3) cleanup_nocodb_logs ;;
    4) check_nocodb_resources ;;
    5) reset_nocodb_admin_password ;;
    0) return ;;
    *) ui_status "error" "Lựa chọn không hợp lệ" ;;
    esac
}

restart_nocodb() {
    ui_run_command "Restart NocoDB" "
        cd $N8N_COMPOSE_DIR && docker compose restart nocodb
    "
    
    if wait_for_nocodb_ready; then
        ui_status "success" "NocoDB đã restart thành công"
    else
        ui_status "error" "NocoDB restart thất bại"
    fi
}

update_nocodb_image() {
    ui_warning_box "Cập nhật NocoDB" \
        "Sẽ pull image mới nhất từ Docker Hub" \
        "Service sẽ tạm thời gián đoạn"
    
    if ! ui_confirm "Tiếp tục update?"; then
        return
    fi
    
    ui_run_command "Pull NocoDB image mới" "
        cd $N8N_COMPOSE_DIR && docker compose pull nocodb
    "
    
    ui_run_command "Restart với image mới" "
        cd $N8N_COMPOSE_DIR && docker compose up -d nocodb
    "
    
    if wait_for_nocodb_ready; then
        ui_status "success" "NocoDB đã được cập nhật"
    else
        ui_status "error" "Cập nhật thất bại"
    fi
}

cleanup_nocodb_logs() {
    ui_run_command "Dọn dẹp Docker logs" "
        docker logs $NOCODB_CONTAINER --tail 0 2>/dev/null || true
    "
    ui_status "success" "Logs đã được dọn dẹp"
}

check_nocodb_resources() {
    ui_section "Tài nguyên NocoDB"
    
    local database_mode=$(config_get "nocodb.database_mode" "shared")
    local nocodb_domain=$(config_get "nocodb.domain" "")
    
    echo "Database mode: $database_mode"
    if [[ -n "$nocodb_domain" ]]; then
        echo "Domain: $nocodb_domain"
    fi
    echo ""
    
    if docker ps --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
        local container_id=$(docker ps -q --filter "name=^${NOCODB_CONTAINER}$")
        
        echo "📊 Resource Usage:"
        docker stats "$container_id" --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
        
        echo ""
        echo "💾 Volume Usage:"
        docker system df -v | grep nocodb || echo "Không có volumes NocoDB"
        
        if [[ "$database_mode" == "separate" ]]; then
            echo ""
            echo "🗄️  Database riêng cho NocoDB:"
            local db_size=$(docker exec n8n-postgres psql -U nocodb -d nocodb -c "SELECT pg_size_pretty(pg_database_size('nocodb'));" -t 2>/dev/null | xargs)
            echo "Size: ${db_size:-Unknown}"
        fi
    else
        ui_status "error" "NocoDB container không chạy"
    fi
}

reset_nocodb_admin_password() {
    ui_section "Reset Admin Password"
    
    local new_password=$(generate_random_string 16)
    
    # Update .env file
    sed -i "s/NOCODB_ADMIN_PASSWORD=.*/NOCODB_ADMIN_PASSWORD=$new_password/" "$N8N_COMPOSE_DIR/.env"
    
    # Update password file
    echo "$new_password" > "$N8N_COMPOSE_DIR/.nocodb-admin-password"
    chmod 600 "$N8N_COMPOSE_DIR/.nocodb-admin-password"
    
    # Restart để apply password mới
    restart_nocodb
    
    ui_info_box "Password mới" \
        "Email: $(config_get "nocodb.admin_email")" \
        "Password: $new_password" \
        "" \
        "💡 Password đã được lưu vào file .nocodb-admin-password"
}

show_nocodb_logs() {
    ui_section "NocoDB Logs"
    
    if ! docker ps --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
        ui_status "error" "NocoDB container không chạy"
        return 1
    fi
    
    echo "1) 📝 Logs gần nhất (50 dòng)"
    echo "2) 📝 Follow logs real-time"
    echo "3) 📝 Logs với timestamp"
    echo "4) 📝 Error logs only"
    echo "0) ⬅️  Quay lại"
    echo ""
    
    read -p "Chọn [0-4]: " log_choice
    
    case "$log_choice" in
    1) docker logs --tail 50 "$NOCODB_CONTAINER" ;;
    2) 
        echo "📝 Live logs (Ctrl+C để thoát):"
        docker logs -f "$NOCODB_CONTAINER"
        ;;
    3) docker logs -t --tail 50 "$NOCODB_CONTAINER" ;;
    4) docker logs "$NOCODB_CONTAINER" 2>&1 | grep -i "error\|exception\|fail" ;;
    0) return ;;
    *) ui_status "error" "Lựa chọn không hợp lệ" ;;
    esac
}