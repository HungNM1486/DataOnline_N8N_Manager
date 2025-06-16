#!/bin/bash

# DataOnline N8N Manager - Bộ Test Tổng hợp
set -euo pipefail

# Màu sắc
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RED='\033[0;31m'
readonly TEST_YELLOW='\033[1;33m'
readonly TEST_BLUE='\033[0;34m'
readonly TEST_NC='\033[0m'

# Kết quả test
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Theo dõi kết quả test
run_test() {
    local test_name="$1"
    local test_script="$2"
    
    echo -e "${TEST_BLUE}[TEST]${TEST_NC} Đang chạy: $test_name"
    
    if bash "$test_script" >/dev/null 2>&1; then
        echo -e "${TEST_GREEN}[THÀNH CÔNG]${TEST_NC} $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${TEST_RED}[THẤT BẠI]${TEST_NC} $test_name"
        ((TESTS_FAILED++))
    fi
    
    ((TESTS_TOTAL++))
}

# Test runner chính
main() {
    echo "DataOnline N8N Manager - Bộ Test Tổng hợp"
    echo "========================================="
    echo ""
    
    # Test core framework
    echo "Đang test Core Framework..."
    run_test "Hệ thống Logger" "tests/test-logger.sh"
    run_test "Quản lý Cấu hình" "tests/test-config.sh"
    run_test "Thư viện Tiện ích" "tests/test-utils.sh"
    
    echo ""
    echo "Kết quả Test:"
    echo "============="
    echo -e "Tổng test: $TESTS_TOTAL"
    echo -e "${TEST_GREEN}Thành công: $TESTS_PASSED${TEST_NC}"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${TEST_RED}Thất bại: $TESTS_FAILED${TEST_NC}"
    else
        echo -e "Thất bại: $TESTS_FAILED"
    fi
    
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${TEST_GREEN}Tất cả test đều thành công! ✅${TEST_NC}"
        exit 0
    else
        echo -e "${TEST_RED}Một số test thất bại! ❌${TEST_NC}"
        exit 1
    fi
}

main "$@"