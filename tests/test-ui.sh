#!/bin/bash

# Test UI System
source src/core/ui.sh
source src/core/spinner.sh

echo "Testing DataOnline UI System..."
echo ""

# Test header
ui_header "DataOnline N8N Manager UI Test"

# Test section
ui_section "Spinner Tests"

# Test basic spinner
echo "Testing basic spinner..."
ui_start_spinner "Đang tải dữ liệu"
sleep 2
ui_stop_spinner
ui_status "success" "Spinner cơ bản hoạt động"
echo ""

# Test command execution
ui_section "Command Execution Tests"

ui_run_command "Kiểm tra hệ thống" "ls -la /tmp > /dev/null"
ui_run_command "Test command thất bại" "false" "false" || true
echo ""

# Test prompts (interactive - comment out for non-interactive testing)
: '
ui_section "Interactive Prompt Tests"

domain=$(ui_prompt "Nhập domain" "example.com" "^[a-zA-Z0-9.-]+$" "Domain không hợp lệ")
echo "Domain đã nhập: $domain"

if ui_confirm "Bạn có muốn tiếp tục không?"; then
    echo "Người dùng chọn tiếp tục"
else
    echo "Người dùng chọn không tiếp tục"
fi
'

# Test status display
ui_section "Status Display Tests"

ui_status "success" "Cài đặt thành công"
ui_status "error" "Kết nối thất bại"
ui_status "warning" "Cảnh báo bộ nhớ thấp"
ui_status "info" "Thông tin hệ thống"
echo ""

# Test info boxes
ui_section "Info Box Tests"

ui_info_box "Thông tin hệ thống" \
    "OS: Ubuntu 24.04 LTS" \
    "RAM: 4GB" \
    "Disk: 50GB available"

ui_warning_box "Cảnh báo" \
    "Hành động này sẽ xóa toàn bộ dữ liệu" \
    "Không thể hoàn tác sau khi thực hiện" \
    "Hãy đảm bảo đã backup dữ liệu"
echo ""

# Test specialized spinners
ui_section "Specialized Spinner Tests"

network_spinner "Kiểm tra kết nối internet" "ping -c 1 8.8.8.8"
install_spinner "Mô phỏng cài đặt package" "sleep 1"
config_spinner "Tạo cấu hình" "sleep 1"
echo ""

# Test progress
ui_section "Progress Tests"

for i in {1..5}; do
    ui_show_progress $i 5 "Xử lý bước $i/5"
    sleep 0.5
done
echo ""

# Test validation
ui_section "Validation Tests"

test_domains=("google.com" "invalid-domain" "test.example.org" "not_valid")
for domain in "${test_domains[@]}"; do
    if ui_validate_domain "$domain"; then
        ui_status "success" "Domain hợp lệ: $domain"
    else
        ui_status "error" "Domain không hợp lệ: $domain"
    fi
done

test_emails=("test@example.com" "invalid-email" "user@domain.org" "bad@email")
for email in "${test_emails[@]}"; do
    if ui_validate_email "$email"; then
        ui_status "success" "Email hợp lệ: $email"
    else
        ui_status "error" "Email không hợp lệ: $email"
    fi
done

test_ports=("80" "8080" "65535" "70000" "abc")
for port in "${test_ports[@]}"; do
    if ui_validate_port "$port"; then
        ui_status "success" "Port hợp lệ: $port"
    else
        ui_status "error" "Port không hợp lệ: $port"
    fi
done

echo ""
ui_status "success" "Tất cả tests hoàn thành!"