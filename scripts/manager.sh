#!/bin/bash

# DataOnline N8N Manager
# Version: 0.1.0-dev
# Author: DataOnline Team

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# Config
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly VERSION="0.1.0-dev"

# Logging functions
log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Main menu
show_main_menu() {
    clear
    echo -e "${CYAN}╭──────────────────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│                DataOnline N8N Manager                     │${NC}"
    echo -e "${CYAN}│                Development Version                       │${NC}"
    echo -e "${CYAN}│                   https://DataOnline.vn                    │${NC}"
    echo -e "${CYAN}╰──────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "${WHITE}CHỨC NĂNG CHÍNH:${NC}"
    echo -e "1️⃣  🚀 Cài đặt N8N"
    echo -e "2️⃣  🌐 Quản lý tên miền & SSL"
    echo -e "3️⃣  ⚙️  Quản lý dịch vụ"
    echo -e "4️⃣  �� Sao lưu & khôi phục"
    echo -e "5️⃣  🔄 Cập nhật phiên bản"
    echo ""
    echo -e "${WHITE}HỖ TRỢ:${NC}"
    echo -e "A️⃣  📋 Thông tin hệ thống"
    echo -e "B️⃣  🔧 Cấu hình"
    echo -e "C️⃣  📚 Trợ giúp & tài liệu"
    echo ""
    echo -e "0️⃣  ❌ Thoát"
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────${NC}"
}

# Handle menu selection
handle_selection() {
    local choice="$1"

    case "$choice" in
    1)
        log_info "Chức năng cài đặt N8N - Coming soon..."
        ;;
    2)
        log_info "Chức năng quản lý domain - Coming soon..."
        ;;
    3)
        log_info "Chức năng quản lý dịch vụ - Coming soon..."
        ;;
    4)
        log_info "Chức năng backup & restore - Coming soon..."
        ;;
    5)
        log_info "Chức năng update - Coming soon..."
        ;;
    A | a)
        show_system_info
        ;;
    B | b)
        log_info "Chức năng cấu hình - Coming soon..."
        ;;
    C | c)
        show_help
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

# System information
show_system_info() {
    echo ""
    log_info "THÔNG TIN HỆ THỐNG:"
    echo "OS: $(lsb_release -d | cut -f2)"
    echo "Kernel: $(uname -r)"
    echo "CPU: $(nproc) cores"
    echo "RAM: $(free -h | awk '/^Mem:/ {print $2}')"
    echo "Disk: $(df -h / | awk 'NR==2 {print $4 " available"}')"

    if command -v docker >/dev/null 2>&1; then
        echo "Docker: $(docker --version | cut -d' ' -f3 | cut -d',' -f1)"
    else
        echo "Docker: Not installed"
    fi

    if command -v node >/dev/null 2>&1; then
        echo "Node.js: $(node --version)"
    else
        echo "Node.js: Not installed"
    fi
    echo ""
}

# Help information
show_help() {
    echo ""
    log_info "TRỢ GIÚP:"
    echo "• Website: https://DataOnline.vn"
    echo "• Documentation: https://docs.DataOnline.vn/n8n-manager"
    echo "• Support: support@DataOnline.vn"
    echo "• GitHub: https://github.com/DataOnline-vn/n8n-manager"
    echo ""
    echo "Phiên bản: $VERSION"
    echo "Môi trường: Development"
    echo ""
}

# Main loop
main() {
    while true; do
        show_main_menu
        read -p "Nhập lựa chọn [1-5, A-C, 0]: " choice
        echo ""
        handle_selection "$choice"
        echo ""
        read -p "Nhấn Enter để tiếp tục..."
    done
}

# Run main function
main "$@"
