#!/bin/bash

# DataOnline N8N Manager - Plugin Backup
# Phiên bản: 1.0.0
# Mô tả: Backup tự động n8n với Google Drive support

set -euo pipefail

# Source core modules
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_PROJECT_ROOT="$(dirname "$(dirname "$PLUGIN_DIR")")"

# Source modules if not loaded
[[ -z "${LOGGER_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/logger.sh"
[[ -z "${CONFIG_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/config.sh"
[[ -z "${UTILS_LOADED:-}" ]] && source "$PLUGIN_PROJECT_ROOT/src/core/utils.sh"

# Constants
readonly BACKUP_BASE_DIR="/opt/n8n/backups"
readonly RCLONE_CONFIG="$HOME/.config/rclone/rclone.conf"
readonly CRON_JOB_NAME="n8n-backup"

# ===== BACKUP FUNCTIONS =====

# Tạo backup n8n
create_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="n8n_backup_${timestamp}"
    local backup_dir="$BACKUP_BASE_DIR/$backup_name"

    log_info "🔄 Bắt đầu backup n8n..." >&2

    # Tạo thư mục backup
    sudo mkdir -p "$backup_dir"

    # 1. Backup PostgreSQL database
    log_info "📦 Backup database PostgreSQL..." >&2
    if sudo docker exec n8n-postgres pg_dump -U n8n n8n >"$backup_dir/database.sql"; then
        log_success "✅ Database backup thành công" >&2
    else
        log_error "❌ Database backup thất bại" >&2
        return 1
    fi

    # 2. Backup n8n data files
    log_info "📁 Backup n8n data files..." >&2
    local n8n_volume=$(sudo docker volume inspect --format '{{ .Mountpoint }}' n8n_n8n_data 2>/dev/null)

    if [[ -n "$n8n_volume" ]]; then
        sudo tar -czf "$backup_dir/n8n_data.tar.gz" -C "$n8n_volume" .
        log_success "✅ Data files backup thành công" >&2
    else
        log_error "❌ Không tìm thấy n8n data volume" >&2
        return 1
    fi

    # 3. Backup docker-compose và config
    log_info "⚙️ Backup cấu hình..." >&2
    sudo cp /opt/n8n/docker-compose.yml "$backup_dir/"
    sudo cp /opt/n8n/.env "$backup_dir/" 2>/dev/null || true

    # 4. Tạo metadata
    cat >"$backup_dir/metadata.json" <<EOF
{
    "timestamp": "$(date -Iseconds)",
    "version": "$(sudo docker exec n8n n8n --version 2>/dev/null || echo "unknown")",
    "type": "full",
    "size": "$(du -sh "$backup_dir" | cut -f1)"
}
EOF

    # 5. Nén toàn bộ backup
    log_info "🗜️ Đang nén backup..." >&2
    cd "$BACKUP_BASE_DIR"
    sudo tar -czf "${backup_name}.tar.gz" "$backup_name"
    sudo rm -rf "$backup_name"

    log_success "✅ Backup hoàn tất: ${backup_name}.tar.gz" >&2

    # Chỉ echo đường dẫn file, không có log messages
    echo "$BACKUP_BASE_DIR/${backup_name}.tar.gz"
}

# Upload backup lên Google Drive
upload_to_gdrive() {
    local backup_file="$1"
    local remote_name="${2:-gdrive}"

    if [[ ! -f "$RCLONE_CONFIG" ]]; then
        log_error "❌ Chưa cấu hình Google Drive"
        return 1
    fi

    log_info "☁️ Đang upload lên Google Drive..."

    if rclone copy "$backup_file" "${remote_name}:n8n-backups/" --progress; then
        log_success "✅ Upload thành công"
        return 0
    else
        log_error "❌ Upload thất bại"
        return 1
    fi
}

# Cleanup backup cũ
cleanup_old_backups() {
    local retention_days=$(config_get "backup.retention_days" "30")

    log_info "🧹 Dọn dẹp backup cũ hơn $retention_days ngày..."

    # Local cleanup
    find "$BACKUP_BASE_DIR" -name "n8n_backup_*.tar.gz" -mtime +$retention_days -delete

    # Google Drive cleanup (if configured)
    if [[ -f "$RCLONE_CONFIG" ]]; then
        rclone delete "gdrive:n8n-backups" --min-age "${retention_days}d" --include "n8n_backup_*.tar.gz"
    fi
}

# ===== RESTORE FUNCTIONS =====

# Restore từ backup
restore_backup() {
    local backup_file="$1"

    log_info "🔄 Bắt đầu restore từ backup..."

    # Kiểm tra file backup
    if [[ ! -f "$backup_file" ]]; then
        log_error "❌ File backup không tồn tại: $backup_file"
        return 1
    fi

    # Extract backup
    local temp_dir="/tmp/n8n_restore_$(date +%s)"
    mkdir -p "$temp_dir"

    log_info "📦 Đang giải nén backup..."
    tar -xzf "$backup_file" -C "$temp_dir"

    local backup_dir=$(find "$temp_dir" -name "n8n_backup_*" -type d | head -1)

    # Stop n8n
    log_info "⏹️ Dừng n8n services..."
    cd /opt/n8n
    sudo docker compose down

    # Restore database
    log_info "🗄️ Restore database..."
    sudo docker compose up -d postgres
    sleep 5

    sudo docker exec -i n8n-postgres psql -U n8n -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
    sudo docker exec -i n8n-postgres psql -U n8n n8n <"$backup_dir/database.sql"

    # Restore data files
    log_info "📁 Restore data files..."
    local n8n_volume=$(sudo docker volume inspect --format '{{ .Mountpoint }}' n8n_n8n_data)
    sudo rm -rf "$n8n_volume"/*
    sudo tar -xzf "$backup_dir/n8n_data.tar.gz" -C "$n8n_volume"

    # Start n8n
    log_info "▶️ Khởi động lại n8n..."
    sudo docker compose up -d

    # Cleanup
    rm -rf "$temp_dir"

    log_success "✅ Restore hoàn tất!"
}

# ===== CRON JOB MANAGEMENT =====

# Cài đặt cron job
setup_cron_job() {
    local frequency="$1" # daily, weekly, monthly
    local hour="${2:-2}" # Default 2 AM

    log_info "⏰ Cài đặt backup tự động..."

    # Tạo script wrapper
    local cron_script="/usr/local/bin/n8n-backup-cron.sh"

    # Sử dụng cat với sudo tee để tránh vấn đề với heredoc
    cat <<EOF | sudo tee "$cron_script" >/dev/null
#!/bin/bash
# N8N Backup Cron Script
export PATH="/usr/local/bin:/usr/bin:/bin"

# Đường dẫn tới thư mục backup và plugin
BACKUP_DIR="/opt/n8n/backups"
PLUGIN_DIR="$PLUGIN_DIR"
PROJECT_ROOT="$PLUGIN_PROJECT_ROOT"

# Source backup plugin trực tiếp
source "\$PROJECT_ROOT/src/core/logger.sh"
source "\$PROJECT_ROOT/src/core/config.sh"
source "\$PROJECT_ROOT/src/core/utils.sh"
source "\$PLUGIN_DIR/main.sh"

# Tạo backup
log_info "Starting automated backup..."
backup_file=\$(create_backup)

# Upload to Google Drive if configured
if [[ -f "\$HOME/.config/rclone/rclone.conf" ]] && [[ -n "\$backup_file" ]]; then
    upload_to_gdrive "\$backup_file"
fi

# Cleanup old backups
cleanup_old_backups
EOF

    sudo chmod +x "$cron_script"

    # Set cron schedule
    local cron_schedule
    case "$frequency" in
    "daily") cron_schedule="0 $hour * * *" ;;
    "weekly") cron_schedule="0 $hour * * 0" ;;
    "monthly") cron_schedule="0 $hour 1 * *" ;;
    *) cron_schedule="0 2 1 * *" ;; # Default monthly
    esac

    # Add to crontab
    (
        crontab -l 2>/dev/null | grep -v "$CRON_JOB_NAME"
        echo "$cron_schedule $cron_script # $CRON_JOB_NAME"
    ) | crontab -

    log_success "✅ Đã cài đặt backup $frequency lúc $hour:00"
}

# ===== GOOGLE DRIVE SETUP =====

# Cấu hình Google Drive
setup_google_drive() {
    log_info "☁️ CẤU HÌNH GOOGLE DRIVE BACKUP"
    echo ""

    # Cài đặt rclone nếu chưa có
    if ! command_exists rclone; then
        log_info "📦 Cài đặt rclone..."
        curl https://rclone.org/install.sh | sudo bash
    fi

    # Kiểm tra cấu hình hiện tại
    if [[ -f "$RCLONE_CONFIG" ]] && rclone listremotes | grep -q "gdrive:"; then
        log_info "✅ Google Drive đã được cấu hình"
        read -p "Bạn muốn cấu hình lại? [y/N]: " reconfigure
        [[ ! "$reconfigure" =~ ^[Yy]$ ]] && return 0
    fi

    log_info "📝 Hướng dẫn cấu hình Google Drive:"
    echo ""
    echo "1. Truy cập: https://console.cloud.google.com"
    echo "2. Tạo project mới hoặc chọn project có sẵn"
    echo "3. Enable Google Drive API"
    echo "4. Tạo OAuth 2.0 credentials"
    echo "5. Download file credentials"
    echo ""

    read -p "Nhấn Enter khi đã sẵn sàng..."

    # Chạy rclone config
    rclone config

    # Test connection
    log_info "🧪 Kiểm tra kết nối..."
    if rclone lsd gdrive: >/dev/null 2>&1; then
        log_success "✅ Kết nối Google Drive thành công!"

        # Tạo thư mục backup
        rclone mkdir gdrive:n8n-backups
    else
        log_error "❌ Không thể kết nối Google Drive"
        return 1
    fi
}

# ===== MENU FUNCTIONS =====

# Menu chính backup
backup_menu_main() {
    while true; do
        echo ""
        log_info "💾 QUẢN LÝ BACKUP N8N"
        echo ""
        echo "1) 🔄 Tạo backup ngay"
        echo "2) 📥 Restore từ backup"
        echo "3) ⏰ Cấu hình backup tự động"
        echo "4) ☁️  Cấu hình Google Drive"
        echo "5) 📋 Xem danh sách backup"
        echo "6) 🧹 Dọn dẹp backup cũ"
        echo "0) ⬅️  Quay lại"
        echo ""

        read -p "Chọn [0-6]: " choice

        case "$choice" in
        1) backup_create_now ;;
        2) backup_restore_menu ;;
        3) backup_schedule_menu ;;
        4) setup_google_drive ;;
        5) backup_list ;;
        6) backup_cleanup_menu ;;
        0) return ;;
        *) log_error "Lựa chọn không hợp lệ" ;;
        esac
    done
}

# Cải thiện function backup_create_now
backup_create_now() {
    log_info "🔄 TẠO BACKUP NGAY"

    # Capture chỉ đường dẫn file, logs đã được redirect sang stderr
    local backup_file
    backup_file=$(create_backup)

    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        log_success "Backup file: $(basename "$backup_file")"

        # Hỏi upload Google Drive
        if [[ -f "$RCLONE_CONFIG" ]]; then
            read -p "Upload lên Google Drive? [Y/n]: " upload
            if [[ ! "$upload" =~ ^[Nn]$ ]]; then
                upload_to_gdrive "$backup_file"
            fi
        fi
    else
        log_error "❌ Backup thất bại hoặc file không tồn tại"
    fi
}

# Menu restore
backup_restore_menu() {
    log_info "📥 RESTORE TỪ BACKUP"
    echo ""

    # Liệt kê backup local
    echo "Backup local:"
    local backups=($(ls -t "$BACKUP_BASE_DIR"/n8n_backup_*.tar.gz 2>/dev/null))

    if [[ ${#backups[@]} -eq 0 ]]; then
        log_warn "Không có backup local"
    else
        for i in "${!backups[@]}"; do
            local backup="${backups[$i]}"
            local size=$(du -h "$backup" | cut -f1)
            local date=$(stat -c %y "$backup" | cut -d' ' -f1)
            echo "$((i + 1))) $(basename "$backup") - $size - $date"
        done
    fi

    echo ""
    read -p "Chọn backup để restore [1-${#backups[@]}]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#backups[@]} ]]; then
        local selected_backup="${backups[$((choice - 1))]}"

        log_warn "⚠️  CẢNH BÁO: Restore sẽ ghi đè toàn bộ data hiện tại!"
        read -p "Bạn chắc chắn muốn restore? [y/N]: " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            restore_backup "$selected_backup"
        fi
    else
        log_error "Lựa chọn không hợp lệ"
    fi
}

# Menu lịch backup
backup_schedule_menu() {
    log_info "⏰ CẤU HÌNH BACKUP TỰ ĐỘNG"
    echo ""

    echo "Tần suất backup:"
    echo "1) Hàng ngày"
    echo "2) Hàng tuần"
    echo "3) Hàng tháng (mặc định)"
    echo ""

    read -p "Chọn tần suất [1-3]: " freq_choice

    local frequency="monthly"
    case "$freq_choice" in
    1) frequency="daily" ;;
    2) frequency="weekly" ;;
    3) frequency="monthly" ;;
    esac

    read -p "Giờ backup (0-23, mặc định 2): " hour
    hour=${hour:-2}

    if [[ ! "$hour" =~ ^[0-9]+$ ]] || [[ "$hour" -lt 0 ]] || [[ "$hour" -gt 23 ]]; then
        log_error "Giờ không hợp lệ"
        return
    fi

    setup_cron_job "$frequency" "$hour"

    # Lưu config
    config_set "backup.schedule" "$frequency"
    config_set "backup.hour" "$hour"
}

# Liệt kê backup
backup_list() {
    log_info "📋 DANH SÁCH BACKUP"
    echo ""

    echo "=== Backup Local ==="
    if [[ -d "$BACKUP_BASE_DIR" ]]; then
        ls -lh "$BACKUP_BASE_DIR"/n8n_backup_*.tar.gz 2>/dev/null || echo "Không có backup"
    fi

    echo ""

    if [[ -f "$RCLONE_CONFIG" ]]; then
        echo "=== Backup Google Drive ==="
        rclone ls gdrive:n8n-backups/ 2>/dev/null || echo "Không thể truy cập Google Drive"
    fi
}

# Menu cleanup
backup_cleanup_menu() {
    log_info "🧹 DỌN DẸP BACKUP CŨ"
    echo ""

    local retention_days=$(config_get "backup.retention_days" "30")
    echo "Retention hiện tại: $retention_days ngày"
    echo ""

    read -p "Nhập số ngày retention mới (Enter để giữ nguyên): " new_retention

    if [[ -n "$new_retention" ]] && [[ "$new_retention" =~ ^[0-9]+$ ]]; then
        config_set "backup.retention_days" "$new_retention"
        retention_days=$new_retention
    fi

    cleanup_old_backups
}

# ===== INIT FUNCTION =====

# Khởi tạo backup khi cài n8n
init_backup_on_install() {
    log_info "🔧 Khởi tạo backup tự động..."

    # Tạo thư mục backup
    sudo mkdir -p "$BACKUP_BASE_DIR"

    # Setup cron job mặc định (monthly)
    setup_cron_job "monthly" "2"

    # Tạo manager environment file
    sudo tee /opt/n8n/manager-env.sh >/dev/null <<EOF
# DataOnline N8N Manager Environment
export MANAGER_PATH="$PLUGIN_PROJECT_ROOT"
export BACKUP_DIR="$BACKUP_BASE_DIR"
EOF

    log_success "✅ Đã cài đặt backup tự động hàng tháng"
}

# Export functions
export -f backup_menu_main
export -f init_backup_on_install
export -f create_backup
export -f cleanup_old_backups
