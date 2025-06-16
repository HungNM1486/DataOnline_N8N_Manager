#!/bin/bash

# Test chức năng logger
source src/core/logger.sh

echo "Đang test DataOnline Logger..."
echo ""

log_debug "Đây là tin nhắn debug"
log_info "Đây là tin nhắn thông tin"
log_warn "Đây là tin nhắn cảnh báo"
log_error "Đây là tin nhắn lỗi"
log_success "Đây là tin nhắn thành công"

echo ""
log_custom "TÙY CHỈNH" "Đây là tin nhắn tùy chỉnh" "$LOG_BLUE"

echo ""
log_info "Vị trí file log: $LOG_FILE"

# Test cấp độ log
echo ""
log_info "Đang test cấp độ log..."
set_log_level "warn"
log_debug "Debug này không nên hiển thị"
log_info "Info này không nên hiển thị"
log_warn "Cảnh báo này nên hiển thị"

set_log_level "info"
log_info "Đã reset cấp độ log về info"
