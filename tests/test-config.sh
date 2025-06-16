#!/bin/bash

# Test chức năng cấu hình
source src/core/config.sh

echo "Đang test DataOnline Configuration Manager..."
echo ""

# Test basic get/set
log_info "Đang test cấu hình cơ bản..."
echo "Tên ứng dụng: $(config_get "app.name")"
echo "Port N8N: $(config_get "n8n.port")"
echo "Chế độ debug: $(config_get "app.debug")"

echo ""
log_info "Đang thiết lập giá trị tùy chỉnh..."
config_set "app.debug" "true" false
config_set "test.value" "xin chào thế giới" false

echo "Chế độ debug: $(config_get "app.debug")"
echo "Giá trị test: $(config_get "test.value")"

echo ""
log_info "Đang test validation..."
validate_config

echo ""
log_info "Hiển thị toàn bộ cấu hình..."
show_config