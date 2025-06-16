#!/bin/bash

# Test chức năng tiện ích
source src/core/utils.sh

echo "Đang test DataOnline Utility Functions..."
echo ""

# Test kiểm tra hệ thống
log_info "Đang test yêu cầu hệ thống..."
check_system_requirements

echo ""
log_info "Đang test các hàm validation..."
echo "Domain hợp lệ (google.com): $(is_valid_domain "google.com" && echo "✅" || echo "❌")"
echo "Domain không hợp lệ (google): $(is_valid_domain "google" && echo "❌" || echo "✅")"
echo "IP hợp lệ (8.8.8.8): $(is_valid_ip "8.8.8.8" && echo "✅" || echo "❌")"
echo "IP không hợp lệ (999.999.999.999): $(is_valid_ip "999.999.999.999" && echo "❌" || echo "✅")"
echo "Email hợp lệ (test@example.com): $(is_valid_email "test@example.com" && echo "✅" || echo "❌")"

echo ""
log_info "Đang test các hàm tiện ích..."
echo "Phiên bản Ubuntu: $(get_ubuntu_version)"
echo "Chạy với quyền root: $(is_root && echo "Có" || echo "Không")"
echo "Chuỗi ngẫu nhiên: $(generate_random_string 16)"

echo ""
log_info "Đang test khả năng sử dụng port..."
echo "Port 22 có sẵn: $(is_port_available 22 && echo "Có" || echo "Không")"
echo "Port 65534 có sẵn: $(is_port_available 65534 && echo "Có" || echo "Không")"

echo ""
log_info "Đang test chuyển đổi thời gian..."
echo "3661 giây = $(seconds_to_human 3661)"
echo "90061 giây = $(seconds_to_human 90061)"
