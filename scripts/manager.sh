#!/bin/bash

# DataOnline N8N Manager
# Phiên bản: 1.0.0-dev
# Tác giả: DataOnline Team

set -euo pipefail

# Lấy thư mục script
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source các module core
source "$PROJECT_ROOT/src/core/logger.sh"
source "$PROJECT_ROOT/src/core/config.sh"
source "$PROJECT_ROOT/src/core/utils.sh"

# Thông tin ứng dụng
readonly APP_NAME="$(config_get "app.name")"
readonly APP_VERSION="$(config_get "app.version")"

# Khởi tạo ứng dụng
init_app() {
    log_debug "Đang khởi tạo DataOnline N8N Manager..."

    # Thiết lập log level từ config
    local log_level
    log_level=$(config_get "logging.level")
    set_log_level "$log_level"

    log_debug "Ứng dụng đã được khởi tạo"
}

# Menu chính
show_main_menu() {
    clear
    echo -e "${LOG_CYAN}╭──────────────────────────────────────────────────────────╮${LOG_NC}"
    echo -e "${LOG_CYAN}│                $APP_NAME                     │${LOG_NC}"
    echo -e "${LOG_CYAN}│                Phiên bản phát triển v$APP_VERSION                │${LOG_NC}"
    echo -e "${LOG_CYAN}│                   https://datalonline.vn                 │${LOG_NC}"
    echo -e "${LOG_CYAN}╰──────────────────────────────────────────────────────────╯${LOG_NC}"
    echo ""
    echo -e "${LOG_WHITE}CHỨC NĂNG CHÍNH:${LOG_NC}"
    echo -e "1️⃣  🚀 Cài đặt N8N"
    echo -e "2️⃣  🌐 Quản lý tên miền & SSL"
    echo -e "3️⃣  ⚙️  Quản lý dịch vụ"
    echo -e "4️⃣  💾 Sao lưu & khôi phục"
    echo -e "5️⃣  🔄 Cập nhật phiên bản"
    echo ""
    echo -e "${LOG_WHITE}HỖ TRỢ:${LOG_NC}"
    echo -e "A️⃣  📋 Thông tin hệ thống"
    echo -e "B️⃣  🔧 Cấu hình"
    echo -e "C️⃣  📚 Trợ giúp & tài liệu"
    echo -e "D️⃣  🧪 Chế độ debug"
    echo ""
    echo -e "0️⃣  ❌ Thoát"
    echo ""
    echo -e "${LOG_CYAN}───────────────────────────────────────────────────────────${LOG_NC}"
}

# Xử lý lựa chọn menu
handle_selection() {
    local choice="$1"

    case "$choice" in
    1)
        handle_installation
        ;;
    2)
        handle_domain_management
        ;;
    3)
        handle_service_management
        ;;
    4)
        handle_backup_restore
        ;;
    5)
        handle_updates
        ;;
    A | a)
        show_system_info
        ;;
    B | b)
        show_configuration_menu
        ;;
    C | c)
        show_help
        ;;
    D | d)
        toggle_debug_mode
        ;;
    0)
        log_success "Cảm ơn bạn đã sử dụng DataOnline N8N Manager!"
        exit 0
        ;;
    *)
        log_error "Lựa chọn không hợp lệ: $choice"
        ;;
    esac
}

# Xử lý cài đặt
handle_installation() {
    # Source plugin cài đặt
    local install_plugin="$PROJECT_ROOT/src/plugins/install/main.sh"
    
    if [[ -f "$install_plugin" ]]; then
        source "$install_plugin"
        # Gọi hàm main của plugin
        install_n8n_main
    else
        log_error "Không tìm thấy plugin cài đặt"
        log_info "Đường dẫn: $install_plugin"
        return 1
    fi
}

# Xử lý quản lý domain
handle_domain_management() {
    log_info "QUẢN LÝ TÊN MIỀN & SSL"
    echo ""
    log_info "Tính năng này sẽ sớm có sẵn..."
}

# Xử lý quản lý dịch vụ
handle_service_management() {
    log_info "QUẢN LÝ DỊCH VỤ"
    echo ""

    echo "Các dịch vụ có sẵn:"
    echo "• N8N: $(is_service_running "n8n" && echo "Đang chạy ✅" || echo "Đã dừng ❌")"
    echo "• Nginx: $(is_service_running "nginx" && echo "Đang chạy ✅" || echo "Đã dừng ❌")"
    echo "• Docker: $(is_service_running "docker" && echo "Đang chạy ✅" || echo "Đã dừng ❌")"
    echo ""
}

# Xử lý backup & restore
handle_backup_restore() {
    log_info "SAO LƯU & KHÔI PHỤC"
    echo ""
    log_info "Tính năng này sẽ sớm có sẵn..."
}

# Xử lý updates
handle_updates() {
    log_info "CẬP NHẬT PHIÊN BẢN"
    echo ""
    log_info "Phiên bản hiện tại: $APP_VERSION"
    log_info "Tính năng này sẽ sớm có sẵn..."
}

# Thông tin hệ thống nâng cao
show_system_info() {
    echo ""
    log_info "THÔNG TIN HỆ THỐNG:"
    echo ""

    echo "════════════════════════════════════════"
    echo "Thông tin OS:"
    echo "  OS: $(lsb_release -d | cut -f2)"
    echo "  Kernel: $(uname -r)"
    echo "  Kiến trúc: $(uname -m)"
    echo ""

    echo "Phần cứng:"
    echo "  CPU: $(nproc) cores"
    echo "  RAM: $(free -h | awk '/^Mem:/ {print $2}') tổng, $(free -h | awk '/^Mem:/ {print $7}') có sẵn"
    echo "  Đĩa: $(df -h / | awk 'NR==2 {print $4}') có sẵn trên /"
    echo ""

    echo "Mạng:"
    if command_exists curl; then
        local public_ip
        if public_ip=$(get_public_ip); then
            echo "  IP công khai: $public_ip"
        else
            echo "  IP công khai: Không thể xác định"
        fi
    fi
    echo "  Hostname: $(hostname)"
    echo ""

    echo "Dịch vụ:"
    echo "  Docker: $(command_exists docker && echo "$(docker --version | cut -d' ' -f3 | cut -d',' -f1)" || echo "Chưa cài đặt")"
    echo "  Node.js: $(command_exists node && echo "$(node --version)" || echo "Chưa cài đặt")"
    echo "  Nginx: $(command_exists nginx && echo "$(nginx -v 2>&1 | cut -d' ' -f3)" || echo "Chưa cài đặt")"
    echo ""

    echo "DataOnline Manager:"
    echo "  Phiên bản: $APP_VERSION"
    echo "  File cấu hình: $CONFIG_FILE"
    echo "  File log: $(config_get "logging.file")"
    echo "════════════════════════════════════════"
    echo ""
}

# Menu cấu hình
show_configuration_menu() {
    echo ""
    log_info "CẤU HÌNH HỆ THỐNG"
    echo ""

    echo "1) Xem cấu hình hiện tại"
    echo "2) Thay đổi log level"
    echo "3) Kiểm tra cấu hình"
    echo "0) Quay lại"
    echo ""

    read -p "Chọn [0-3]: " config_choice

    case "$config_choice" in
    1) show_config ;;
    2) change_log_level ;;
    3) validate_config ;;
    0) return ;;
    *) log_error "Lựa chọn không hợp lệ: $config_choice" ;;
    esac
}

# Thay đổi log level
change_log_level() {
    echo ""
    log_info "THAY ĐỔI LOG LEVEL"
    echo ""

    echo "Log level hiện tại: $(config_get "logging.level")"
    echo ""
    echo "Các level có sẵn:"
    echo "1) debug - Hiện tất cả tin nhắn"
    echo "2) info - Hiện info, cảnh báo, lỗi"
    echo "3) warn - Chỉ hiện cảnh báo và lỗi"
    echo "4) error - Chỉ hiện lỗi"
    echo ""

    read -p "Chọn level [1-4]: " level_choice

    case "$level_choice" in
    1) config_set "logging.level" "debug" && set_log_level "debug" ;;
    2) config_set "logging.level" "info" && set_log_level "info" ;;
    3) config_set "logging.level" "warn" && set_log_level "warn" ;;
    4) config_set "logging.level" "error" && set_log_level "error" ;;
    *) log_error "Lựa chọn không hợp lệ: $level_choice" ;;
    esac
}

# Bật/tắt debug mode
toggle_debug_mode() {
    local current_debug
    current_debug=$(config_get "app.debug")

    if [[ "$current_debug" == "true" ]]; then
        config_set "app.debug" "false"
        set_log_level "info"
        log_success "Đã tắt chế độ debug"
    else
        config_set "app.debug" "true"
        set_log_level "debug"
        log_success "Đã bật chế độ debug"
    fi
}

# Thông tin trợ giúp
show_help() {
    echo ""
    log_info "TRỢ GIÚP & TÀI LIỆU"
    echo ""

    echo "════════════════════════════════════════"
    echo "Liên hệ hỗ trợ:"
    echo "  • Website: https://datalonline.vn"
    echo "  • Tài liệu: https://docs.datalonline.vn/n8n-manager"
    echo "  • Hỗ trợ: support@datalonline.vn"
    echo "  • GitHub: https://github.com/datalonline-vn/n8n-manager"
    echo ""
    echo "Phím tắt:"
    echo "  • Ctrl+C: Thoát khẩn cấp"
    echo "  • Enter: Tiếp tục"
    echo ""
    echo "Thông tin phiên bản:"
    echo "  • Phiên bản: $APP_VERSION"
    echo "  • Build: Development"
    echo "  • Hỗ trợ: Ubuntu 24.04+"
    echo "════════════════════════════════════════"
    echo ""
}

# Vòng lặp chính
main() {
    # Khởi tạo ứng dụng
    init_app

    log_debug "Bắt đầu vòng lặp ứng dụng chính"

    while true; do
        show_main_menu
        read -p "Nhập lựa chọn [1-5, A-D, 0]: " choice
        echo ""
        handle_selection "$choice"
        echo ""
        read -p "Nhấn Enter để tiếp tục..."
    done
}

# Chạy hàm main
main "$@"
