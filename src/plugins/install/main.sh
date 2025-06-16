#!/bin/bash

# DataOnline N8N Manager - Plugin Cài đặt N8N
# Phiên bản: 1.0.0
# Mô tả: Plugin cài đặt n8n với Docker và PostgreSQL

set -euo pipefail

# Source core modules
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_PROJECT_ROOT="$(dirname "$(dirname "$PLUGIN_DIR")")"

# Kiểm tra xem core modules đã được load chưa
if [[ -z "${LOGGER_LOADED:-}" ]]; then
    source "$PLUGIN_PROJECT_ROOT/src/core/logger.sh"
fi
if [[ -z "${CONFIG_LOADED:-}" ]]; then
    source "$PLUGIN_PROJECT_ROOT/src/core/config.sh"
fi
if [[ -z "${UTILS_LOADED:-}" ]]; then
    source "$PLUGIN_PROJECT_ROOT/src/core/utils.sh"
fi

# Constants cho plugin
readonly DOCKER_COMPOSE_VERSION="2.24.5"
readonly REQUIRED_RAM_MB=2048 # 2GB RAM tối thiểu
readonly REQUIRED_DISK_GB=10  # 10GB disk tối thiểu
readonly N8N_DEFAULT_PORT=5678
readonly POSTGRES_DEFAULT_PORT=5432

# Biến global cho installation
INSTALL_TYPE="" # docker, native, migrate
N8N_PORT=""
POSTGRES_PORT=""
N8N_DOMAIN=""
N8N_WEBHOOK_URL=""

# ===== PHẦN 1: KIỂM TRA HỆ THỐNG =====

# Kiểm tra yêu cầu hệ thống cho n8n
check_n8n_requirements() {
    log_info "🔍 Đang kiểm tra yêu cầu hệ thống cho n8n..."
    local errors=0

    # Kiểm tra OS version
    local ubuntu_version
    ubuntu_version=$(get_ubuntu_version)

    if [[ "${ubuntu_version%%.*}" -lt 18 ]]; then
        log_error "❌ Yêu cầu Ubuntu 18.04 trở lên (hiện tại: $ubuntu_version)"
        ((errors++))
    else
        log_success "✅ Ubuntu version: $ubuntu_version"
    fi

    # Kiểm tra RAM
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/^Mem:/ {print $2}')

    if [[ "$total_ram_mb" -lt "$REQUIRED_RAM_MB" ]]; then
        log_error "❌ RAM không đủ: ${total_ram_mb}MB (yêu cầu >= ${REQUIRED_RAM_MB}MB)"
        ((errors++))
    else
        log_success "✅ RAM: ${total_ram_mb}MB"
    fi

    # Kiểm tra CPU cores
    local cpu_cores
    cpu_cores=$(nproc)

    if [[ "$cpu_cores" -lt 2 ]]; then
        log_warn "⚠️  CPU cores: $cpu_cores (khuyến nghị >= 2)"
    else
        log_success "✅ CPU cores: $cpu_cores"
    fi

    # Kiểm tra disk space
    local free_disk_gb
    free_disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')

    if [[ "$free_disk_gb" -lt "$REQUIRED_DISK_GB" ]]; then
        log_error "❌ Dung lượng đĩa không đủ: ${free_disk_gb}GB (yêu cầu >= ${REQUIRED_DISK_GB}GB)"
        ((errors++))
    else
        log_success "✅ Dung lượng đĩa trống: ${free_disk_gb}GB"
    fi

    # Kiểm tra kết nối internet
    if ! check_internet_connection; then
        log_error "❌ Không có kết nối internet"
        ((errors++))
    else
        log_success "✅ Kết nối internet OK"
    fi

    return $errors
}

# ===== PHẦN 2: CÀI ĐẶT DEPENDENCIES =====

# Cài đặt Docker và Docker Compose
install_docker() {
    log_info "🐳 Đang cài đặt Docker..."

    # Kiểm tra Docker đã cài chưa
    if command_exists docker; then
        local docker_version
        docker_version=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
        log_success "✅ Docker đã được cài đặt: $docker_version"
        return 0
    fi

    # Cài đặt Docker
    log_info "📦 Đang cài đặt Docker từ repository chính thức..."

    # Xóa phiên bản cũ nếu có
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Cài đặt dependencies
    sudo apt-get update
    sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Thêm Docker GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    # Thêm Docker repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    # Cài đặt Docker Engine
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Thêm user hiện tại vào docker group
    sudo usermod -aG docker "$USER"

    # Khởi động Docker
    sudo systemctl enable docker
    sudo systemctl start docker

    log_success "✅ Docker đã được cài đặt thành công"
    log_warn "⚠️  Bạn cần logout và login lại để sử dụng Docker không cần sudo"
}

# Cài đặt các dependencies khác
install_dependencies() {
    log_info "📦 Đang cài đặt các dependencies cần thiết..."

    local packages=(
        "nginx"             # Reverse proxy
        "postgresql-client" # PostgreSQL client tools
        "jq"                # JSON processing
        "curl"              # HTTP client
        "wget"              # Download tool
        "git"               # Version control
        "htop"              # System monitoring
        "ncdu"              # Disk usage analyzer
    )

    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log_info "📥 Đang cài đặt $package..."
            sudo apt-get install -y "$package"
        else
            log_debug "✓ $package đã được cài đặt"
        fi
    done

    log_success "✅ Đã cài đặt tất cả dependencies"
}

# ===== PHẦN 3: CHỌN PHƯƠNG THỨC CÀI ĐẶT =====

# Menu chọn phương thức cài đặt
show_install_method_menu() {
    echo ""
    log_info "🚀 CHỌN PHƯƠNG THỨC CÀI ĐẶT N8N"
    echo ""
    echo "1) 🐳 Cài đặt với Docker (Khuyến nghị)"
    echo "   - Dễ quản lý và nâng cấp"
    echo "   - Tự động cấu hình PostgreSQL"
    echo "   - Isolation tốt hơn"
    echo ""
    echo "2) 📦 Cài đặt Native (Nâng cao)"
    echo "   - Performance tốt hơn"
    echo "   - Yêu cầu cấu hình thủ công nhiều hơn"
    echo ""
    echo "3) 🔄 Migration từ n8n hiện có"
    echo "   - Chuyển đổi từ cài đặt cũ"
    echo "   - Giữ nguyên workflows và credentials"
    echo ""
    echo "0) ❌ Quay lại"
    echo ""

    read -p "Chọn phương thức [1-3, 0]: " choice

    case "$choice" in
    1) INSTALL_TYPE="docker" ;;
    2) INSTALL_TYPE="native" ;;
    3) INSTALL_TYPE="migrate" ;;
    0) return 1 ;;
    *)
        log_error "Lựa chọn không hợp lệ: $choice"
        return 1
        ;;
    esac

    return 0
}

# ===== PHẦN 4: CẤU HÌNH CƠ BẢN =====

# Thu thập thông tin cấu hình từ user
collect_configuration() {
    log_info "⚙️  CẤU HÌNH CƠ BẢN CHO N8N"
    echo ""

    # Port cho n8n
    while true; do
        read -p "Port cho n8n (mặc định $N8N_DEFAULT_PORT): " N8N_PORT
        N8N_PORT=${N8N_PORT:-$N8N_DEFAULT_PORT}

        if [[ ! "$N8N_PORT" =~ ^[0-9]+$ ]] || [[ "$N8N_PORT" -lt 1 ]] || [[ "$N8N_PORT" -gt 65535 ]]; then
            log_error "Port không hợp lệ: $N8N_PORT"
            continue
        fi

        if ! is_port_available "$N8N_PORT"; then
            log_error "Port $N8N_PORT đã được sử dụng"
            continue
        fi

        break
    done

    # Port cho PostgreSQL (chỉ cho Docker)
    if [[ "$INSTALL_TYPE" == "docker" ]]; then
        while true; do
            read -p "Port cho PostgreSQL (mặc định $POSTGRES_DEFAULT_PORT): " POSTGRES_PORT
            POSTGRES_PORT=${POSTGRES_PORT:-$POSTGRES_DEFAULT_PORT}

            if [[ ! "$POSTGRES_PORT" =~ ^[0-9]+$ ]] || [[ "$POSTGRES_PORT" -lt 1 ]] || [[ "$POSTGRES_PORT" -gt 65535 ]]; then
                log_error "Port không hợp lệ: $POSTGRES_PORT"
                continue
            fi

            if ! is_port_available "$POSTGRES_PORT"; then
                log_error "Port $POSTGRES_PORT đã được sử dụng"
                continue
            fi

            break
        done
    fi

    # Domain (tùy chọn)
    read -p "Domain cho n8n (để trống nếu chưa có): " N8N_DOMAIN

    if [[ -n "$N8N_DOMAIN" ]]; then
        if ! is_valid_domain "$N8N_DOMAIN"; then
            log_warn "⚠️  Domain có vẻ không hợp lệ: $N8N_DOMAIN"
            read -p "Bạn có chắc muốn sử dụng domain này? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                N8N_DOMAIN=""
            fi
        fi
    fi

    # Webhook URL
    if [[ -n "$N8N_DOMAIN" ]]; then
        N8N_WEBHOOK_URL="https://$N8N_DOMAIN"
    else
        local public_ip
        public_ip=$(get_public_ip || echo "localhost")
        N8N_WEBHOOK_URL="http://$public_ip:$N8N_PORT"
    fi

    # Hiển thị tóm tắt cấu hình
    echo ""
    log_info "📋 TÓM TẮT CẤU HÌNH:"
    echo "   • Phương thức: $INSTALL_TYPE"
    echo "   • N8N Port: $N8N_PORT"
    [[ "$INSTALL_TYPE" == "docker" ]] && echo "   • PostgreSQL Port: $POSTGRES_PORT"
    [[ -n "$N8N_DOMAIN" ]] && echo "   • Domain: $N8N_DOMAIN"
    echo "   • Webhook URL: $N8N_WEBHOOK_URL"
    echo ""

    read -p "Xác nhận cấu hình? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return 1

    return 0
}

# ===== PHẦN 5: CÀI ĐẶT DOCKER =====

# Tạo docker-compose.yml cho n8n
create_docker_compose() {
    log_info "📝 Đang tạo file docker-compose.yml..."

    local compose_dir="/opt/n8n"

    # Tạo thư mục với error handling
    if ! sudo mkdir -p "$compose_dir"; then
        log_error "Không thể tạo thư mục $compose_dir"
        return 1
    fi

    # Tạo random password cho PostgreSQL
    local postgres_password
    postgres_password=$(generate_random_string 32)

    # Tạo file tạm trong /tmp trước
    local temp_compose="/tmp/docker-compose-n8n.yml"
    local temp_env="/tmp/env-n8n"

    # Tạo docker-compose.yml trong /tmp
    cat >"$temp_compose" <<EOF
version: '3.8'

services:
  # PostgreSQL Database
  postgres:
    image: postgres:15-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=$postgres_password
      - POSTGRES_DB=n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "$POSTGRES_PORT:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

  # N8N Application
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - N8N_HOST=0.0.0.0
      - N8N_PORT=$N8N_PORT
      - N8N_PROTOCOL=http
      - NODE_ENV=production
      - WEBHOOK_URL=$N8N_WEBHOOK_URL
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      
      # Database configuration
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=$postgres_password
      
      # Execution mode
      - EXECUTIONS_MODE=regular
      - EXECUTIONS_PROCESS=main
      
      # Security
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=changeme
      
      # Metrics (optional)
      - N8N_METRICS=false
    ports:
      - "$N8N_PORT:$N8N_PORT"
    volumes:
      - n8n_data:/home/node/.n8n
      - ./backups:/backups
    networks:
      - n8n-network

volumes:
  postgres_data:
    driver: local
  n8n_data:
    driver: local

networks:
  n8n-network:
    driver: bridge
version: '3.8'

services:
  # PostgreSQL Database
  postgres:
    image: postgres:15-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=$postgres_password
      - POSTGRES_DB=n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "$POSTGRES_PORT:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

  # N8N Application
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - N8N_HOST=0.0.0.0
      - N8N_PORT=$N8N_PORT
      - N8N_PROTOCOL=http
      - NODE_ENV=production
      - WEBHOOK_URL=$N8N_WEBHOOK_URL
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      
      # Database configuration
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=$postgres_password
      
      # Execution mode
      - EXECUTIONS_MODE=regular
      - EXECUTIONS_PROCESS=main
      
      # Security
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=changeme
      
      # Metrics (optional)
      - N8N_METRICS=false
    ports:
      - "$N8N_PORT:$N8N_PORT"
    volumes:
      - n8n_data:/home/node/.n8n
      - ./backups:/backups
    networks:
      - n8n-network

volumes:
  postgres_data:
    driver: local
  n8n_data:
    driver: local

networks:
  n8n-network:
    driver: bridge
EOF

    # Kiểm tra file tạm
    if [[ ! -f "$temp_compose" ]]; then
        log_error "Không thể tạo file docker-compose tạm"
        return 1
    fi

    # Tạo .env file trong /tmp
    cat >"$temp_env" <<EOF
# DataOnline N8N Manager - Environment Variables
# Generated at: $(date)

# N8N Configuration
N8N_PORT=$N8N_PORT
N8N_DOMAIN=$N8N_DOMAIN
N8N_WEBHOOK_URL=$N8N_WEBHOOK_URL

# PostgreSQL Configuration
POSTGRES_PORT=$POSTGRES_PORT
POSTGRES_PASSWORD=$postgres_password

# Backup Configuration
BACKUP_ENABLED=true
BACKUP_RETENTION_DAYS=30
EOF

    # Copy files với sudo
    if ! sudo cp "$temp_compose" "$compose_dir/docker-compose.yml"; then
        log_error "Không thể copy docker-compose.yml"
        rm -f "$temp_compose" "$temp_env"
        return 1
    fi

    if ! sudo cp "$temp_env" "$compose_dir/.env"; then
        log_error "Không thể copy .env file"
        rm -f "$temp_compose" "$temp_env"
        return 1
    fi

    # Set permissions
    sudo chmod 644 "$compose_dir/docker-compose.yml"
    sudo chmod 600 "$compose_dir/.env"

    # Cleanup temp files
    rm -f "$temp_compose" "$temp_env"

    log_success "✅ Đã tạo docker-compose.yml và .env"

    # Lưu cấu hình vào config hệ thống
    config_set "n8n.install_type" "docker"
    config_set "n8n.compose_dir" "$compose_dir"
    config_set "n8n.port" "$N8N_PORT"
    config_set "n8n.webhook_url" "$N8N_WEBHOOK_URL"
}

# Khởi động n8n với Docker
start_n8n_docker() {
    log_info "🚀 Đang khởi động n8n với Docker..."

    local compose_dir="/opt/n8n"
    cd "$compose_dir"

    # Pull images
    log_info "📥 Đang tải Docker images..."
    sudo docker compose pull

    # Start services
    log_info "▶️  Đang khởi động services..."
    sudo docker compose up -d

    # Chờ services khởi động
    log_info "⏳ Đang chờ services khởi động..."

    local max_wait=60
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if curl -s "http://localhost:$N8N_PORT/healthz" >/dev/null 2>&1; then
            log_success "✅ N8N đã khởi động thành công!"
            break
        fi

        sleep 2
        ((waited += 2))
        echo -n "."
    done

    echo ""

    if [[ $waited -ge $max_wait ]]; then
        log_error "❌ Timeout khi chờ n8n khởi động"
        log_info "Kiểm tra logs: sudo docker compose logs"
        return 1
    fi

    return 0
}

# ===== PHẦN 6: TẠO SYSTEMD SERVICE =====

# Tạo systemd service cho Docker Compose
create_systemd_service() {
    log_info "🔧 Đang tạo systemd service..."

    sudo tee /etc/systemd/system/n8n.service >/dev/null <<'EOF'
[Unit]
Description=N8N Workflow Automation
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/n8n
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd và enable service
    sudo systemctl daemon-reload
    sudo systemctl enable n8n.service

    log_success "✅ Đã tạo systemd service"
}

# ===== PHẦN 7: KIỂM TRA CÀI ĐẶT =====

# Health check sau khi cài đặt
verify_installation() {
    log_info "🏥 Đang kiểm tra cài đặt..."

    local errors=0

    # Kiểm tra Docker containers
    if [[ "$INSTALL_TYPE" == "docker" ]]; then
        log_info "Kiểm tra Docker containers..."

        local containers=("n8n" "n8n-postgres")
        for container in "${containers[@]}"; do
            if sudo docker ps --format "table {{.Names}}" | grep -q "^$container$"; then
                log_success "✅ Container $container đang chạy"
            else
                log_error "❌ Container $container không chạy"
                ((errors++))
            fi
        done
    fi

    # Kiểm tra n8n API
    log_info "Kiểm tra N8N API..."
    if curl -s "http://localhost:$N8N_PORT/healthz" >/dev/null 2>&1; then
        log_success "✅ N8N API hoạt động bình thường"
    else
        log_error "❌ N8N API không phản hồi"
        ((errors++))
    fi

    # Kiểm tra database connection
    if [[ "$INSTALL_TYPE" == "docker" ]]; then
        log_info "Kiểm tra kết nối PostgreSQL..."
        if sudo docker exec n8n-postgres pg_isready -U n8n >/dev/null 2>&1; then
            log_success "✅ PostgreSQL hoạt động bình thường"
        else
            log_error "❌ PostgreSQL không hoạt động"
            ((errors++))
        fi
    fi

    # Hiển thị thông tin truy cập
    echo ""
    log_info "📋 THÔNG TIN TRUY CẬP N8N:"
    echo "════════════════════════════════════════"
    echo "   URL: http://localhost:$N8N_PORT"
    [[ -n "$N8N_DOMAIN" ]] && echo "   Domain: https://$N8N_DOMAIN"
    echo "   Username: admin"
    echo "   Password: changeme"
    echo "   ⚠️  QUAN TRỌNG: Hãy đổi password ngay!"
    echo "════════════════════════════════════════"
    echo ""

    if [[ $errors -eq 0 ]]; then
        log_success "✅ Kiểm tra hoàn tất - Tất cả đều hoạt động tốt!"
        return 0
    else
        log_error "❌ Phát hiện $errors lỗi trong quá trình kiểm tra"
        return 1
    fi
}

# ===== PHẦN 8: CHỨC NĂNG MIGRATION =====

# Migration từ n8n instance cũ
migrate_from_existing() {
    log_info "🔄 MIGRATION TỪ N8N HIỆN CÓ"
    echo ""

    # Thu thập thông tin về instance cũ
    log_info "Vui lòng cung cấp thông tin về n8n hiện tại:"
    echo ""

    read -p "N8N hiện tại chạy trên Docker? [Y/n]: " is_docker
    local source_type="native"
    [[ ! "$is_docker" =~ ^[Nn]$ ]] && source_type="docker"

    read -p "Đường dẫn data n8n (mặc định ~/.n8n): " source_path
    source_path=${source_path:-"$HOME/.n8n"}

    if [[ ! -d "$source_path" ]]; then
        log_error "Không tìm thấy thư mục data: $source_path"
        return 1
    fi

    # Backup data cũ
    log_info "📦 Đang backup data hiện tại..."
    local backup_name="n8n-backup-$(date +%Y%m%d-%H%M%S)"
    local backup_path="/tmp/$backup_name"

    cp -r "$source_path" "$backup_path"
    log_success "✅ Đã backup vào: $backup_path"

    # Cài đặt n8n mới
    log_info "🚀 Đang cài đặt n8n mới với Docker..."
    INSTALL_TYPE="docker"

    if ! collect_configuration; then
        return 1
    fi

    create_docker_compose
    start_n8n_docker

    # Restore data
    log_info "📥 Đang restore data..."
    sudo docker compose -f /opt/n8n/docker-compose.yml down

    # Copy data files
    sudo cp -r "$backup_path"/* "/var/lib/docker/volumes/n8n_n8n_data/_data/"
    sudo chown -R 1000:1000 "/var/lib/docker/volumes/n8n_n8n_data/_data/"

    # Restart n8n
    sudo docker compose -f /opt/n8n/docker-compose.yml up -d

    log_success "✅ Migration hoàn tất!"

    verify_installation
}

# ===== PHẦN 9: UTILITY FUNCTIONS =====

# Hiển thị hướng dẫn sau cài đặt
show_post_install_guide() {
    echo ""
    log_info "📚 HƯỚNG DẪN SAU CÀI ĐẶT"
    echo "════════════════════════════════════════"
    echo ""
    echo "1. ĐỔI MẬT KHẨU ADMIN:"
    echo "   - Truy cập N8N"
    echo "   - Vào Settings > Users"
    echo "   - Đổi password cho user admin"
    echo ""
    echo "2. CẤU HÌNH NGINX (nếu có domain):"
    echo "   - Chạy: sudo nano /etc/nginx/sites-available/n8n"
    echo "   - Cấu hình reverse proxy"
    echo "   - Enable SSL với Let's Encrypt"
    echo ""
    echo "3. BACKUP TỰ ĐỘNG:"
    echo "   - Backup được lưu tại: /opt/n8n/backups"
    echo "   - Thiết lập cron job cho backup định kỳ"
    echo ""
    echo "4. MONITORING:"
    echo "   - Logs: sudo docker compose -f /opt/n8n/docker-compose.yml logs -f"
    echo "   - Stats: sudo docker stats"
    echo ""
    echo "5. QUẢN LÝ SERVICE:"
    echo "   - Start: sudo systemctl start n8n"
    echo "   - Stop: sudo systemctl stop n8n"
    echo "   - Restart: sudo systemctl restart n8n"
    echo "   - Status: sudo systemctl status n8n"
    echo ""
    echo "════════════════════════════════════════"
}

# Rollback khi có lỗi
rollback_installation() {
    log_warn "⚠️  Đang rollback cài đặt do có lỗi..."

    if [[ "$INSTALL_TYPE" == "docker" ]]; then
        # Stop và remove containers
        if [[ -f "/opt/n8n/docker-compose.yml" ]]; then
            cd /opt/n8n
            sudo docker compose down -v
        fi

        # Remove systemd service
        if [[ -f "/etc/systemd/system/n8n.service" ]]; then
            sudo systemctl disable n8n.service
            sudo rm -f /etc/systemd/system/n8n.service
            sudo systemctl daemon-reload
        fi

        # Remove config directory
        sudo rm -rf /opt/n8n
    fi

    log_info "Đã rollback các thay đổi"
}

# ===== MAIN FUNCTION - ĐIỀU PHỐI QUÁ TRÌNH CÀI ĐẶT =====

# Hàm chính của plugin
install_n8n_main() {
    log_info "🚀 BẮT ĐẦU CÀI ĐẶT N8N"
    echo ""

    # Bước 1: Kiểm tra hệ thống
    if ! check_n8n_requirements; then
        log_error "Hệ thống không đáp ứng yêu cầu tối thiểu"
        return 1
    fi

    echo ""
    read -p "Tiếp tục cài đặt? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return 0

    # Bước 2: Chọn phương thức cài đặt
    if ! show_install_method_menu; then
        return 0
    fi

    # Trap để rollback khi có lỗi
    trap rollback_installation ERR

    # Bước 3: Xử lý theo phương thức đã chọn
    case "$INSTALL_TYPE" in
    "docker")
        # Cài đặt dependencies
        install_dependencies
        install_docker

        # Thu thập cấu hình
        if ! collect_configuration; then
            return 1
        fi

        # Tạo và khởi động n8n
        create_docker_compose
        start_n8n_docker
        create_systemd_service
        ;;

    "native")
        log_warn "⚠️  Cài đặt Native chưa được implement trong phiên bản này"
        log_info "Vui lòng chọn cài đặt Docker"
        return 1
        ;;

    "migrate")
        migrate_from_existing
        ;;
    esac

    # Bước 4: Verify installation
    if verify_installation; then
        show_post_install_guide

        # Lưu trạng thái cài đặt
        config_set "n8n.installed" "true"
        config_set "n8n.installed_date" "$(date -Iseconds)"
    else
        log_error "Cài đặt không thành công hoàn toàn"
        return 1
    fi

    # Remove trap
    trap - ERR

    return 0
}

# Export function để manager.sh có thể gọi
export -f install_n8n_main
