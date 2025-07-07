#!/bin/bash

# DataOnline N8N Manager - NocoDB Setup & Docker Integration
# Phiên bản: 1.0.0

set -euo pipefail

# ===== DOCKER INTEGRATION FUNCTIONS =====

setup_nocodb_integration() {
    ui_section "Cài đặt NocoDB Integration"
    
    # Step 1: Generate secrets
    if ! generate_nocodb_secrets; then
        ui_status "error" "Tạo secrets thất bại"
        return 1
    fi
    
    # Step 2: Backup current docker-compose
    if ! backup_docker_compose; then
        ui_status "error" "Backup docker-compose thất bại"  
        return 1
    fi
    
    # Step 3: Update docker-compose.yml
    if ! update_docker_compose_for_nocodb; then
        ui_status "error" "Cập nhật docker-compose thất bại"
        return 1
    fi
    
    # Step 4: Start NocoDB service
    if ! start_nocodb_service; then
        ui_status "error" "Khởi động NocoDB thất bại"
        rollback_docker_compose
        return 1
    fi
    
    # Step 5: Wait for NocoDB ready
    if ! wait_for_nocodb_ready; then
        ui_status "error" "NocoDB không thể khởi động"
        rollback_docker_compose
        return 1
    fi
    
    # Step 6: Configure database connection
    if ! configure_nocodb_database; then
        ui_status "error" "Cấu hình database thất bại"
        return 1
    fi
    
    ui_status "success" "NocoDB integration hoàn tất!"
    return 0
}

# ===== SECRETS GENERATION =====

generate_nocodb_secrets() {
    ui_start_spinner "Tạo security secrets"
    
    local jwt_secret=$(generate_random_string 64)
    local admin_password=$(generate_random_string 16)
    local admin_email="admin@$(config_get "n8n.domain" "localhost")"
    
    # Check if .env exists
    if [[ ! -f "$N8N_COMPOSE_DIR/.env" ]]; then
        ui_stop_spinner
        ui_status "error" "File .env không tồn tại tại $N8N_COMPOSE_DIR"
        return 1
    fi
    
    # Add NocoDB config to .env if not exists
    if ! grep -q "NOCODB_JWT_SECRET" "$N8N_COMPOSE_DIR/.env"; then
        cat >> "$N8N_COMPOSE_DIR/.env" << EOF

# NocoDB Configuration - Added by DataOnline Manager
NOCODB_JWT_SECRET=$jwt_secret
NOCODB_ADMIN_EMAIL=$admin_email
NOCODB_ADMIN_PASSWORD=$admin_password
NOCODB_PUBLIC_URL=https://db.$(config_get "n8n.domain" "localhost")
EOF
    fi
    
    # Save admin password to separate file for easy access
    echo "$admin_password" > "$N8N_COMPOSE_DIR/.nocodb-admin-password"
    chmod 600 "$N8N_COMPOSE_DIR/.nocodb-admin-password"
    
    # Update config
    config_set "nocodb.admin_email" "$admin_email"
    config_set "nocodb.installed" "true"
    config_set "nocodb.installed_date" "$(date -Iseconds)"
    
    ui_stop_spinner
    ui_status "success" "Secrets đã được tạo"
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
        ui_status "success" "docker-compose.yml đã được cập nhật"
        return 0
    else
        ui_stop_spinner
        ui_status "error" "Cập nhật docker-compose.yml thất bại"
        return 1
    fi
}

add_nocodb_service_to_compose() {
    local compose_file="$1"
    local temp_file="/tmp/docker-compose-nocodb.yml"
    
    # Create backup
    cp "$compose_file" "${compose_file}.backup"
    
    # Use sed to insert NocoDB service before volumes section
    sed '/^volumes:/i\
  # NocoDB Database Manager - Added by DataOnline Manager\
  nocodb:\
    image: nocodb/nocodb:latest\
    container_name: n8n-nocodb\
    restart: unless-stopped\
    environment:\
      - NC_DB=pg://n8n:${POSTGRES_PASSWORD}@postgres:5432/n8n\
      - NC_PUBLIC_URL=${NOCODB_PUBLIC_URL}\
      - NC_AUTH_JWT_SECRET=${NOCODB_JWT_SECRET}\
      - NC_ADMIN_EMAIL=${NOCODB_ADMIN_EMAIL}\
      - NC_ADMIN_PASSWORD=${NOCODB_ADMIN_PASSWORD}\
      - NC_DISABLE_TELE=true\
      - NC_DASHBOARD_URL=/dashboard\
      - DATABASE_URL=postgres://n8n:${POSTGRES_PASSWORD}@postgres:5432/n8n\
    ports:\
      - "8080:8080"\
    depends_on:\
      postgres:\
        condition: service_healthy\
    volumes:\
      - nocodb_data:/usr/app/data\
      - ./nocodb-config:/usr/app/config\
    networks:\
      - n8n-network\
    healthcheck:\
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/v1/health"]\
      interval: 30s\
      timeout: 10s\
      retries: 3\
      start_period: 60s\
' "$compose_file" > "$temp_file"
    
    # Validate the new compose file
    if docker compose -f "$temp_file" config >/dev/null 2>&1; then
        mv "$temp_file" "$compose_file"
        rm -f "${compose_file}.backup"
        return 0
    else
        # Restore backup on failure
        mv "${compose_file}.backup" "$compose_file"
        rm -f "$temp_file"
        return 1
    fi
}

insert_nocodb_service() {
    local compose_file="$1"
    local nocodb_config="$2"
    local temp_compose="/tmp/docker-compose-updated.yml"
    
    # Create backup of original
    cp "$compose_file" "${compose_file}.backup"
    
    # Find where to insert NocoDB service (after n8n service)
    # We'll insert it before the "volumes:" section
    if grep -q "^volumes:" "$compose_file"; then
        # Insert before volumes section
        sed '/^volumes:/i\
  # NocoDB Database Manager - Added by DataOnline Manager\
  nocodb:\
    image: nocodb/nocodb:latest\
    container_name: n8n-nocodb\
    restart: unless-stopped\
    environment:\
      - NC_DB=pg://n8n:${POSTGRES_PASSWORD}@postgres:5432/n8n\
      - NC_PUBLIC_URL=${NOCODB_PUBLIC_URL}\
      - NC_AUTH_JWT_SECRET=${NOCODB_JWT_SECRET}\
      - NC_ADMIN_EMAIL=${NOCODB_ADMIN_EMAIL}\
      - NC_ADMIN_PASSWORD=${NOCODB_ADMIN_PASSWORD}\
      - NC_DISABLE_TELE=true\
      - NC_DASHBOARD_URL=/dashboard\
      - DATABASE_URL=postgres://n8n:${POSTGRES_PASSWORD}@postgres:5432/n8n\
    ports:\
      - "8080:8080"\
    depends_on:\
      postgres:\
        condition: service_healthy\
    volumes:\
      - nocodb_data:/usr/app/data\
      - ./nocodb-config:/usr/app/config\
    networks:\
      - n8n-network\
    healthcheck:\
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/v1/health"]\
      interval: 30s\
      timeout: 10s\
      retries: 3\
      start_period: 60s\
' "$compose_file" > "$temp_compose"
    else
        # No volumes section, add service at end of services
        awk '
            /^networks:/ { 
                print ""
                print "  # NocoDB Database Manager - Added by DataOnline Manager"
                print "  nocodb:"
                print "    image: nocodb/nocodb:latest"
                print "    container_name: n8n-nocodb"
                print "    restart: unless-stopped"
                print "    environment:"
                print "      - NC_DB=pg://n8n:${POSTGRES_PASSWORD}@postgres:5432/n8n"
                print "      - NC_PUBLIC_URL=${NOCODB_PUBLIC_URL}"
                print "      - NC_AUTH_JWT_SECRET=${NOCODB_JWT_SECRET}"
                print "      - NC_ADMIN_EMAIL=${NOCODB_ADMIN_EMAIL}"
                print "      - NC_ADMIN_PASSWORD=${NOCODB_ADMIN_PASSWORD}"
                print "      - NC_DISABLE_TELE=true"
                print "      - NC_DASHBOARD_URL=/dashboard"
                print "      - DATABASE_URL=postgres://n8n:${POSTGRES_PASSWORD}@postgres:5432/n8n"
                print "    ports:"
                print "      - \"8080:8080\""
                print "    depends_on:"
                print "      postgres:"
                print "        condition: service_healthy"
                print "    volumes:"
                print "      - nocodb_data:/usr/app/data"
                print "      - ./nocodb-config:/usr/app/config"
                print "    networks:"
                print "      - n8n-network"
                print "    healthcheck:"
                print "      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost:8080/api/v1/health\"]"
                print "      interval: 30s"
                print "      timeout: 10s"
                print "      retries: 3"
                print "      start_period: 60s"
                print ""
            }
            { print }
        ' "$compose_file" > "$temp_compose"
    fi
    
    # Validate the new compose file
    if docker compose -f "$temp_compose" config >/dev/null 2>&1; then
        mv "$temp_compose" "$compose_file"
        return 0
    else
        # Restore backup on failure
        mv "${compose_file}.backup" "$compose_file"
        rm -f "$temp_compose"
        return 1
    fi
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

wait_for_nocodb_ready() {
    ui_start_spinner "Chờ NocoDB sẵn sàng"
    
    local max_wait=120  # 2 minutes
    local waited=0
    local health_url="http://localhost:$NOCODB_PORT/api/v1/health"
    
    while [[ $waited -lt $max_wait ]]; do
        if curl -s "$health_url" >/dev/null 2>&1; then
            ui_stop_spinner
            ui_status "success" "NocoDB đã sẵn sàng"
            return 0
        fi
        
        sleep 2
        ((waited += 2))
    done
    
    ui_stop_spinner
    ui_status "error" "Timeout chờ NocoDB khởi động"
    return 1
}

configure_nocodb_database() {
    ui_start_spinner "Cấu hình kết nối database"
    
    # NocoDB will auto-connect via environment variables
    # Just verify the connection works
    local api_url="http://localhost:$NOCODB_PORT/api/v1/db/meta/projects"
    
    if curl -s "$api_url" >/dev/null 2>&1; then
        ui_stop_spinner
        ui_status "success" "Database connection OK"
        return 0
    else
        ui_stop_spinner
        ui_status "error" "Database connection failed"
        return 1
    fi
}

# ===== ROLLBACK FUNCTIONS =====

rollback_docker_compose() {
    ui_start_spinner "Rolling back docker-compose changes"
    
    local backup_dir="$N8N_COMPOSE_DIR/backups"
    local latest_backup=$(ls -t "$backup_dir"/docker-compose.yml.backup_* 2>/dev/null | head -1)
    
    if [[ -n "$latest_backup" ]]; then
        cp "$latest_backup" "$N8N_COMPOSE_DIR/docker-compose.yml"
        
        # Stop NocoDB if running
        cd "$N8N_COMPOSE_DIR"
        docker compose stop nocodb 2>/dev/null || true
        docker compose rm -f nocodb 2>/dev/null || true
        
        ui_stop_spinner
        ui_status "success" "Đã rollback docker-compose"
    else
        ui_stop_spinner
        ui_status "error" "Không tìm thấy backup để rollback"
    fi
}

# ===== REMOVAL FUNCTIONS =====

remove_nocodb_integration() {
    ui_section "Gỡ bỏ NocoDB integration"
    
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
    
    # Clean up volumes (optional)
    echo -n -e "${UI_YELLOW}Xóa dữ liệu NocoDB? [y/N]: ${UI_NC}"
    read -r remove_data
    if [[ "$remove_data" =~ ^[Yy]$ ]]; then
        remove_nocodb_data
    fi
    
    # Clean up config
    clean_nocodb_config
    
    ui_status "success" "NocoDB đã được gỡ bỏ hoàn toàn"
    return 0
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
    ui_start_spinner "Xóa dữ liệu NocoDB"
    
    # Remove volume
    docker volume rm n8n_nocodb_data 2>/dev/null || true
    
    # Remove config files
    rm -rf "$N8N_COMPOSE_DIR/nocodb-config" 2>/dev/null || true
    rm -f "$N8N_COMPOSE_DIR/.nocodb-admin-password" 2>/dev/null || true
    
    ui_stop_spinner
    ui_status "success" "Dữ liệu đã được xóa"
}

clean_nocodb_config() {
    # Remove from .env file
    if [[ -f "$N8N_COMPOSE_DIR/.env" ]]; then
        sed -i '/# NocoDB Configuration/,/^$/d' "$N8N_COMPOSE_DIR/.env"
    fi
    
    # Remove from manager config
    config_set "nocodb.installed" "false"
    config_set "nocodb.admin_email" ""
    
    ui_status "success" "Cấu hình đã được dọn dẹp"
}

# ===== MAINTENANCE FUNCTIONS =====

nocodb_maintenance() {
    ui_section "Bảo trì NocoDB"
    
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
    
    if docker ps --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
        local container_id=$(docker ps -q --filter "name=^${NOCODB_CONTAINER}$")
        
        echo "📊 Resource Usage:"
        docker stats "$container_id" --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
        
        echo ""
        echo "💾 Volume Usage:"
        docker system df -v | grep nocodb || echo "Không có volumes NocoDB"
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