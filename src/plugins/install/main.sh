#!/bin/bash

# DataOnline N8N Manager - Enhanced Install Plugin with UI
# Phiên bản: 1.0.0

set -euo pipefail

# Source core modules
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_PROJECT_ROOT="$(dirname "$(dirname "$PLUGIN_DIR")")"

# Load core modules
if [[ -z "${LOGGER_LOADED:-}" ]]; then
    source "$PLUGIN_PROJECT_ROOT/src/core/logger.sh"
fi
if [[ -z "${CONFIG_LOADED:-}" ]]; then
    source "$PLUGIN_PROJECT_ROOT/src/core/config.sh"
fi
if [[ -z "${UTILS_LOADED:-}" ]]; then
    source "$PLUGIN_PROJECT_ROOT/src/core/utils.sh"
fi
if [[ -z "${UI_LOADED:-}" ]]; then
    source "$PLUGIN_PROJECT_ROOT/src/core/ui.sh"
fi
if [[ -z "${SPINNER_LOADED:-}" ]]; then
    source "$PLUGIN_PROJECT_ROOT/src/core/spinner.sh"
fi

# Constants
readonly INSTALL_DOCKER_COMPOSE_VERSION="2.24.5"
readonly REQUIRED_RAM_MB=2048
readonly REQUIRED_DISK_GB=10
readonly N8N_DEFAULT_PORT=5678
readonly POSTGRES_DEFAULT_PORT=5432

# Global variables
INSTALL_TYPE=""
N8N_PORT=""
POSTGRES_PORT=""
N8N_DOMAIN=""
N8N_WEBHOOK_URL=""

# ===== SYSTEM REQUIREMENTS CHECK =====

check_n8n_requirements() {
    ui_header "Kiểm tra yêu cầu hệ thống"

    local errors=0
    local checks=(
        "check_os_version"
        "check_ram_requirements"
        "check_disk_space"
        "check_cpu_cores"
        "check_internet_connection"
        "check_required_commands"
    )

    for check in "${checks[@]}"; do
        if ! $check; then
            ((errors++))
        fi
    done

    echo ""
    if [[ $errors -eq 0 ]]; then
        ui_status "success" "Tất cả yêu cầu hệ thống đều được đáp ứng"
        return 0
    else
        ui_status "error" "Phát hiện $errors lỗi yêu cầu hệ thống"
        return 1
    fi
}

check_os_version() {
    local ubuntu_version=$(get_ubuntu_version)

    if [[ "${ubuntu_version%%.*}" -lt 18 ]]; then
        ui_status "error" "Ubuntu ${ubuntu_version} - Yêu cầu 18.04+"
        return 1
    else
        ui_status "success" "Ubuntu ${ubuntu_version}"
        return 0
    fi
}

check_ram_requirements() {
    local total_ram_mb=$(free -m | awk '/^Mem:/ {print $2}')

    if [[ "$total_ram_mb" -lt "$REQUIRED_RAM_MB" ]]; then
        ui_status "error" "RAM: ${total_ram_mb}MB (yêu cầu ${REQUIRED_RAM_MB}MB+)"
        return 1
    else
        ui_status "success" "RAM: ${total_ram_mb}MB"
        return 0
    fi
}

check_disk_space() {
    local free_disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')

    if [[ "$free_disk_gb" -lt "$REQUIRED_DISK_GB" ]]; then
        ui_status "error" "Disk: ${free_disk_gb}GB (yêu cầu ${REQUIRED_DISK_GB}GB+)"
        return 1
    else
        ui_status "success" "Disk: ${free_disk_gb}GB available"
        return 0
    fi
}

check_cpu_cores() {
    local cpu_cores=$(nproc)

    if [[ "$cpu_cores" -lt 2 ]]; then
        ui_status "warning" "CPU: $cpu_cores core (khuyến nghị 2+)"
        return 0
    else
        ui_status "success" "CPU: $cpu_cores cores"
        return 0
    fi
}

check_internet_connection() {
    if ping -c 1 -W 2 google.com >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        ui_status "success" "Kết nối internet OK"
        return 0
    else
        ui_status "error" "Không có kết nối internet"
        return 1
    fi
}

check_required_commands() {
    local commands=("curl" "wget" "git" "jq")
    local missing=()

    for cmd in "${commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ui_status "success" "Tất cả commands cần thiết đã có"
        return 0
    else
        ui_status "warning" "Thiếu commands: ${missing[*]} (sẽ cài đặt tự động)"
        return 0
    fi
}

# ===== DEPENDENCIES INSTALLATION =====

install_docker() {
    ui_section "Cài đặt Docker"

    if command_exists docker; then
        local docker_version=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
        ui_status "success" "Docker đã cài đặt: $docker_version"
        return 0
    fi

    # Install Docker
    if ! ui_run_command "Cài đặt Docker dependencies" "sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release"; then
        return 1
    fi

    if ! ui_run_command "Thêm Docker GPG key" "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg"; then
        return 1
    fi

    if ! ui_run_command "Thêm Docker repository" 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null'; then
        return 1
    fi

    if ! ui_run_command "Cài đặt Docker Engine" "sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"; then
        return 1
    fi

    if ! ui_run_command "Cấu hình Docker user" "sudo usermod -aG docker $USER"; then
        return 1
    fi

    if ! ui_run_command "Khởi động Docker" "sudo systemctl enable docker && sudo systemctl start docker"; then
        return 1
    fi

    ui_warning_box "Thông báo quan trọng" \
        "Bạn cần logout và login lại để sử dụng Docker không cần sudo"

    return 0
}

install_dependencies() {
    ui_section "Cài đặt Dependencies"

    local packages=(
        "nginx:Reverse proxy server"
        "postgresql-client:PostgreSQL client tools"
        "jq:JSON processor"
        "curl:HTTP client"
        "wget:Download utility"
        "git:Version control"
        "htop:System monitor"
        "ncdu:Disk usage analyzer"
    )

    ui_show_progress 0 ${#packages[@]} "Chuẩn bị cài đặt packages"

    if ! ui_run_command "Cập nhật package list" "sudo apt-get update"; then
        return 1
    fi

    local i=1
    for package_info in "${packages[@]}"; do
        local package="${package_info%%:*}"
        local description="${package_info##*:}"

        ui_show_progress $i ${#packages[@]} "Cài đặt $package"

        if ! dpkg -l | grep -q "^ii  $package "; then
            if ! install_spinner "Cài đặt $package ($description)" "sudo apt-get install -y $package"; then
                ui_status "error" "Lỗi cài đặt $package"
                return 1
            fi
        else
            ui_status "success" "$package đã cài đặt"
        fi

        ((i++))
    done

    return 0
}

# ===== INSTALLATION METHOD SELECTION =====

show_install_method_menu() {
    ui_header "Chọn phương thức cài đặt N8N"

    ui_info_box "Lưu ý" \
        "Docker là phương thức được khuyến nghị cho người mới" \
        "Native phù hợp với người có kinh nghiệm hệ thống" \
        "Migration giúp chuyển đổi từ N8N cũ"

    echo "1) 🐳 Docker (Khuyến nghị) - Dễ quản lý, tự động PostgreSQL"
    echo "2) 📦 Native - Performance cao, cấu hình thủ công"
    echo "3) 🔄 Migration - Chuyển từ cài đặt cũ"
    echo ""

    while true; do
        echo -n -e "${UI_WHITE}Chọn [1-3]: ${UI_NC}"
        read -r choice

        case "$choice" in
        1)
            INSTALL_TYPE="docker"
            break
            ;;
        2)
            INSTALL_TYPE="native"
            break
            ;;
        3)
            INSTALL_TYPE="migrate"
            break
            ;;
        *) ui_status "error" "Lựa chọn không hợp lệ" ;;
        esac
    done

    ui_status "info" "Đã chọn: $INSTALL_TYPE"
    return 0
}

# ===== CONFIGURATION COLLECTION =====

collect_configuration() {
    ui_header "Cấu hình N8N"

    # N8N Port
    while true; do
        echo -n -e "${UI_WHITE}Port cho N8N (mặc định $N8N_DEFAULT_PORT): ${UI_NC}"
        read -r N8N_PORT
        N8N_PORT=${N8N_PORT:-$N8N_DEFAULT_PORT}

        if ui_validate_port "$N8N_PORT"; then
            if is_port_available "$N8N_PORT"; then
                ui_status "success" "Port N8N: $N8N_PORT"
                break
            else
                ui_status "error" "Port $N8N_PORT đã được sử dụng"
            fi
        else
            ui_status "error" "Port không hợp lệ: $N8N_PORT"
        fi
    done

    # PostgreSQL Port (chỉ cho Docker)
    if [[ "$INSTALL_TYPE" == "docker" ]]; then
        while true; do
            echo -n -e "${UI_WHITE}Port cho PostgreSQL (mặc định $POSTGRES_DEFAULT_PORT): ${UI_NC}"
            read -r POSTGRES_PORT
            POSTGRES_PORT=${POSTGRES_PORT:-$POSTGRES_DEFAULT_PORT}

            if ui_validate_port "$POSTGRES_PORT"; then
                if is_port_available "$POSTGRES_PORT"; then
                    ui_status "success" "Port PostgreSQL: $POSTGRES_PORT"
                    break
                else
                    ui_status "error" "Port $POSTGRES_PORT đã được sử dụng"
                fi
            else
                ui_status "error" "Port không hợp lệ: $POSTGRES_PORT"
            fi
        done
    fi

    # Domain (optional)
    echo -n -e "${UI_WHITE}Domain cho N8N (để trống nếu chưa có): ${UI_NC}"
    read -r N8N_DOMAIN

    if [[ -n "$N8N_DOMAIN" ]] && ! ui_validate_domain "$N8N_DOMAIN"; then
        echo -n -e "${UI_YELLOW}Domain có vẻ không hợp lệ. Bạn có chắc muốn sử dụng '$N8N_DOMAIN'? [y/N]: ${UI_NC}"
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            N8N_DOMAIN=""
        fi
    fi

    # Webhook URL
    if [[ -n "$N8N_DOMAIN" ]]; then
        N8N_WEBHOOK_URL="https://$N8N_DOMAIN"
        ui_status "success" "Domain: $N8N_DOMAIN"
    else
        local public_ip=$(get_public_ip || echo "localhost")
        N8N_WEBHOOK_URL="http://$public_ip:$N8N_PORT"
        ui_status "info" "Sử dụng IP: $public_ip"
    fi

    # Configuration summary
    ui_info_box "Tóm tắt cấu hình" \
        "Phương thức: $INSTALL_TYPE" \
        "N8N Port: $N8N_PORT" \
        "$([ "$INSTALL_TYPE" == "docker" ] && echo "PostgreSQL Port: $POSTGRES_PORT")" \
        "$([ -n "$N8N_DOMAIN" ] && echo "Domain: $N8N_DOMAIN")" \
        "Webhook URL: $N8N_WEBHOOK_URL"

    echo -n -e "${UI_YELLOW}Xác nhận cấu hình? [Y/n]: ${UI_NC}"
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        return 1
    else
        return 0
    fi
}

# ===== DOCKER INSTALLATION =====

create_docker_compose() {
    ui_section "Tạo Docker Compose Configuration"

    local compose_dir="/opt/n8n"

    if ! ui_run_command "Tạo thư mục cài đặt" "sudo mkdir -p $compose_dir"; then
        return 1
    fi

    local postgres_password=$(generate_random_string 32)

    # Create temp files
    local temp_compose="/tmp/docker-compose-n8n.yml"
    local temp_env="/tmp/env-n8n"

    ui_start_spinner "Tạo docker-compose.yml"

    cat >"$temp_compose" <<'DOCKER_EOF'
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=PASSWORD_PLACEHOLDER
      - POSTGRES_DB=n8n
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "PG_PORT_PLACEHOLDER:5432"
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
      - N8N_HOST=0.0.0.0
      - N8N_PORT=PORT_PLACEHOLDER
      - N8N_PROTOCOL=http
      - NODE_ENV=production
      - WEBHOOK_URL=WEBHOOK_PLACEHOLDER
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=PASSWORD_PLACEHOLDER
      - EXECUTIONS_MODE=regular
      - EXECUTIONS_PROCESS=main
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=changeme
      - N8N_METRICS=false
    ports:
      - "PORT_PLACEHOLDER:PORT_PLACEHOLDER"
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
DOCKER_EOF

    # Replace placeholders
    sed -i "s#PASSWORD_PLACEHOLDER#$postgres_password#g" "$temp_compose"
    sed -i "s#PG_PORT_PLACEHOLDER#$POSTGRES_PORT#g" "$temp_compose"
    sed -i "s#PORT_PLACEHOLDER#$N8N_PORT#g" "$temp_compose"
    sed -i "s#WEBHOOK_PLACEHOLDER#$N8N_WEBHOOK_URL#g" "$temp_compose"

    ui_stop_spinner

    # Create .env file
    ui_start_spinner "Tạo file environment"

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

    ui_stop_spinner

    # Copy files
    if ! ui_run_command "Sao chép docker-compose.yml" "sudo cp $temp_compose $compose_dir/docker-compose.yml"; then
        rm -f "$temp_compose" "$temp_env"
        return 1
    fi

    if ! ui_run_command "Sao chép .env file" "sudo cp $temp_env $compose_dir/.env"; then
        rm -f "$temp_compose" "$temp_env"
        return 1
    fi

    # Set permissions
    if ! ui_run_command "Cấp quyền files" "sudo chmod 644 $compose_dir/docker-compose.yml && sudo chmod 600 $compose_dir/.env"; then
        return 1
    fi

    # Cleanup
    rm -f "$temp_compose" "$temp_env"

    # Save config
    config_set "n8n.install_type" "docker"
    config_set "n8n.compose_dir" "$compose_dir"
    config_set "n8n.port" "$N8N_PORT"
    config_set "n8n.webhook_url" "$N8N_WEBHOOK_URL"

    ui_status "success" "Docker Compose configuration tạo thành công"
    return 0
}

start_n8n_docker() {
    ui_section "Khởi động N8N với Docker"

    local compose_dir="/opt/n8n"
    cd "$compose_dir" || return 1

    if ! ui_run_command "Tải Docker images" "sudo docker compose pull"; then
        return 1
    fi

    if ! ui_run_command "Khởi động containers" "sudo docker compose up -d"; then
        return 1
    fi

    # Wait for N8N to be ready
    ui_start_spinner "Chờ N8N khởi động"
    local max_wait=60
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if curl -s "http://localhost:$N8N_PORT/healthz" >/dev/null 2>&1; then
            ui_stop_spinner
            ui_status "success" "N8N đã khởi động thành công!"
            break
        fi
        sleep 2
        ((waited += 2))
    done

    if [[ $waited -ge $max_wait ]]; then
        ui_stop_spinner
        ui_status "error" "Timeout chờ N8N khởi động"
        ui_status "info" "Kiểm tra logs: sudo docker compose logs -f"
        return 1
    fi

    cd - >/dev/null
    return 0
}

# ===== VERIFICATION =====

verify_installation() {
    ui_header "Kiểm tra cài đặt"

    local errors=0

    # Check containers
    if [[ "$INSTALL_TYPE" == "docker" ]]; then
        local containers=("n8n" "n8n-postgres")
        for container in "${containers[@]}"; do
            if sudo docker ps --format "table {{.Names}}" | grep -q "^$container$"; then
                ui_status "success" "Container $container đang chạy"
            else
                ui_status "error" "Container $container không chạy"
                ((errors++))
            fi
        done
    fi

    # Check N8N API
    if curl -s "http://localhost:$N8N_PORT/healthz" >/dev/null 2>&1; then
        ui_status "success" "N8N API hoạt động"
    else
        ui_status "error" "N8N API không phản hồi"
        ((errors++))
    fi

    # Check database
    if [[ "$INSTALL_TYPE" == "docker" ]]; then
        if sudo docker exec n8n-postgres pg_isready -U n8n >/dev/null 2>&1; then
            ui_status "success" "PostgreSQL hoạt động"
        else
            ui_status "error" "PostgreSQL lỗi"
            ((errors++))
        fi
    fi

    # Show access info
    ui_info_box "Thông tin truy cập N8N" \
        "URL: http://localhost:$N8N_PORT" \
        "$([ -n "$N8N_DOMAIN" ] && echo "Domain: https://$N8N_DOMAIN")" \
        "Username: admin" \
        "Password: changeme" \
        "⚠️ QUAN TRỌNG: Đổi password ngay!"

    if [[ $errors -eq 0 ]]; then
        ui_status "success" "Cài đặt hoàn tất - Tất cả dịch vụ hoạt động!"
        return 0
    else
        ui_status "error" "Phát hiện $errors lỗi"
        return 1
    fi
}

# ===== MAIN INSTALLATION FUNCTION =====

install_n8n_main() {
    ui_header "DataOnline N8N Installation"

    # Check for existing installation
    if [[ -d "/opt/n8n" && -f "/opt/n8n/docker-compose.yml" ]]; then
        ui_warning_box "Cảnh báo" \
            "Phát hiện N8N đã được cài đặt" \
            "Sử dụng chức năng 'Xóa N8N và cài đặt lại' để cài đặt lại"

        if ! ui_confirm "Tiếp tục cài đặt?"; then
            return 0
        fi
    fi

    # Step 1: System requirements
    if ! check_n8n_requirements; then
        ui_status "error" "Hệ thống không đáp ứng yêu cầu"
        return 1
    fi

    if ! ui_confirm "Tiếp tục cài đặt?"; then
        return 0
    fi

    # Step 2: Installation method
    if ! show_install_method_menu; then
        return 0
    fi

    # Handle native installation limitation
    if [[ "$INSTALL_TYPE" == "native" ]]; then
        ui_warning_box "Thông báo" \
            "Cài đặt Native chưa được hỗ trợ trong phiên bản này" \
            "Vui lòng chọn Docker installation"
        return 1
    fi

    # Step 3: Configuration
    if ! collect_configuration; then
        return 1
    fi

    # Rollback trap
    trap 'ui_status "error" "Lỗi cài đặt - đang rollback..."; rollback_installation; return 1' ERR

    # Step 4: Install dependencies
    install_dependencies || return 1
    install_docker || return 1

    # Step 5: Docker setup
    case "$INSTALL_TYPE" in
    "docker")
        create_docker_compose || return 1
        start_n8n_docker || return 1
        create_systemd_service || return 1
        ;;
    "migrate")
        ui_status "info" "Migration sẽ được implement trong version tiếp theo"
        return 1
        ;;
    esac

    # Step 6: Verification
    if verify_installation; then
        show_post_install_guide
        config_set "n8n.installed" "true"
        config_set "n8n.installed_date" "$(date -Iseconds)"
        ui_status "success" "🎉 Cài đặt N8N hoàn tất!"
    else
        ui_status "error" "Cài đặt chưa hoàn toàn thành công"
        return 1
    fi

    trap - ERR
    return 0
}

# ===== HELPER FUNCTIONS =====

create_systemd_service() {
    ui_run_command "Tạo systemd service" "sudo tee /etc/systemd/system/n8n.service > /dev/null << 'EOF'
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
sudo systemctl daemon-reload && sudo systemctl enable n8n.service"
}

rollback_installation() {
    ui_status "warning" "Đang rollback cài đặt..."

    if [[ -f "/opt/n8n/docker-compose.yml" ]]; then
        cd /opt/n8n && sudo docker compose down -v || true
    fi

    sudo rm -rf /opt/n8n || true
    sudo rm -f /etc/systemd/system/n8n.service || true
    sudo systemctl daemon-reload || true

    ui_status "info" "Rollback hoàn tất"
}

show_post_install_guide() {
    ui_info_box "Hướng dẫn sau cài đặt" \
        "1. Đổi mật khẩu admin ngay" \
        "2. Cấu hình domain và SSL (nếu có)" \
        "3. Thiết lập backup tự động" \
        "4. Kiểm tra firewall cho port 80/443"

    ui_info_box "Quản lý service" \
        "Start: sudo systemctl start n8n" \
        "Stop: sudo systemctl stop n8n" \
        "Restart: sudo systemctl restart n8n" \
        "Logs: sudo docker compose -f /opt/n8n/docker-compose.yml logs -f"
}

# Export main function
export -f install_n8n_main
