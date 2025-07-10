#!/bin/bash

# Google Drive Debug & Fix Script
# Debug và sửa lỗi kết nối Google Drive với rclone

set -euo pipefail

echo "🔍 GOOGLE DRIVE DEBUG & FIX"
echo "=========================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Step 1: Check rclone installation
echo ""
log_info "Step 1: Checking rclone installation"
if command -v rclone >/dev/null 2>&1; then
    RCLONE_VERSION=$(rclone --version | head -1)
    log_success "✅ rclone installed: $RCLONE_VERSION"
else
    log_error "❌ rclone not installed"
    exit 1
fi

# Step 2: List all remotes
echo ""
log_info "Step 2: Listing all remotes"
REMOTES=$(rclone listremotes 2>/dev/null || true)
if [[ -n "$REMOTES" ]]; then
    log_success "✅ Found remotes:"
    echo "$REMOTES" | sed 's/^/  /'
else
    log_error "❌ No remotes found"
    exit 1
fi

# Step 3: Check specific remote 'n8n'
echo ""
log_info "Step 3: Checking remote 'n8n'"
if echo "$REMOTES" | grep -q "^n8n:$"; then
    log_success "✅ Remote 'n8n' exists"
    
    # Show config
    echo ""
    log_info "Remote 'n8n' configuration:"
    rclone config show n8n | sed 's/^/  /' || log_error "Cannot show config"
    
else
    log_error "❌ Remote 'n8n' not found"
    exit 1
fi

# Step 4: Test connection with different methods
echo ""
log_info "Step 4: Testing connection methods"

# Method 1: Basic test
echo ""
log_info "4.1: Basic connection test"
if rclone lsd n8n: >/dev/null 2>&1; then
    log_success "✅ Basic connection OK"
    CONNECTION_OK=true
else
    log_error "❌ Basic connection failed"
    CONNECTION_OK=false
    
    # Show error details
    echo ""
    log_info "Connection error details:"
    rclone lsd n8n: 2>&1 | head -5 | sed 's/^/  /'
fi

# Method 2: About test (lightweight)
echo ""
log_info "4.2: About API test"
if rclone about n8n: >/dev/null 2>&1; then
    log_success "✅ About API OK"
    ABOUT_OK=true
else
    log_error "❌ About API failed"
    ABOUT_OK=false
fi

# Method 3: Config test
echo ""
log_info "4.3: Config connectivity test"
if rclone config reconnect n8n: >/dev/null 2>&1; then
    log_success "✅ Config reconnect OK"
    CONFIG_OK=true
else
    log_error "❌ Config reconnect failed"
    CONFIG_OK=false
fi

# Step 5: Token analysis
echo ""
log_info "Step 5: Token analysis"
TOKEN_INFO=$(rclone config show n8n | grep -E "(token|expiry)" || true)
if [[ -n "$TOKEN_INFO" ]]; then
    log_info "Token information:"
    echo "$TOKEN_INFO" | sed 's/^/  /'
    
    # Check if token expired
    EXPIRY=$(echo "$TOKEN_INFO" | grep "expiry" | cut -d'=' -f2 | tr -d ' ' || echo "")
    if [[ -n "$EXPIRY" ]]; then
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
        NOW_EPOCH=$(date +%s)
        
        if [[ $EXPIRY_EPOCH -gt $NOW_EPOCH ]]; then
            REMAINING=$((EXPIRY_EPOCH - NOW_EPOCH))
            log_success "✅ Token valid for $((REMAINING/60)) minutes"
        else
            log_warning "⚠️ Token may be expired"
        fi
    fi
else
    log_warning "⚠️ No token information found"
fi

# Step 6: Network test
echo ""
log_info "Step 6: Network connectivity"
if ping -c 1 google.com >/dev/null 2>&1; then
    log_success "✅ Internet connectivity OK"
else
    log_error "❌ No internet connectivity"
fi

# Step 7: Fix attempts
echo ""
log_info "Step 7: Attempting fixes"

if [[ "$CONNECTION_OK" != "true" ]]; then
    echo ""
    log_info "7.1: Attempting token refresh"
    if rclone config reconnect n8n: >/dev/null 2>&1; then
        log_success "✅ Token refresh successful"
        
        # Test again
        if rclone lsd n8n: >/dev/null 2>&1; then
            log_success "✅ Connection now working!"
            CONNECTION_OK=true
        fi
    else
        log_error "❌ Token refresh failed"
    fi
fi

if [[ "$CONNECTION_OK" != "true" ]]; then
    echo ""
    log_info "7.2: Testing specific folder access"
    
    # Try to create a test folder
    TEST_FOLDER="rclone-test-$(date +%s)"
    if rclone mkdir "n8n:$TEST_FOLDER" >/dev/null 2>&1; then
        log_success "✅ Can create folders"
        
        # Cleanup
        rclone rmdir "n8n:$TEST_FOLDER" >/dev/null 2>&1
        CONNECTION_OK=true
    else
        log_error "❌ Cannot create folders"
    fi
fi

# Step 8: Create backup folder test
if [[ "$CONNECTION_OK" == "true" ]]; then
    echo ""
    log_info "Step 8: Testing backup folder creation"
    
    if rclone mkdir n8n:n8n-backups >/dev/null 2>&1; then
        log_success "✅ Created n8n-backups folder"
    else
        # Check if already exists
        if rclone lsd n8n: | grep -q "n8n-backups"; then
            log_success "✅ n8n-backups folder already exists"
        else
            log_error "❌ Cannot create n8n-backups folder"
        fi
    fi
    
    # Test file upload
    echo ""
    log_info "Testing file upload"
    TEST_FILE="/tmp/rclone-test-$(date +%s).txt"
    echo "Test file content" > "$TEST_FILE"
    
    if rclone copy "$TEST_FILE" n8n:n8n-backups/ >/dev/null 2>&1; then
        log_success "✅ File upload works"
        
        # Cleanup
        rclone delete "n8n:n8n-backups/$(basename "$TEST_FILE")" >/dev/null 2>&1
        rm -f "$TEST_FILE"
    else
        log_error "❌ File upload failed"
        rm -f "$TEST_FILE"
    fi
fi

# Step 9: Generate fix commands
echo ""
log_info "Step 9: Recommended actions"

if [[ "$CONNECTION_OK" == "true" ]]; then
    log_success "🎉 Google Drive is working!"
    echo ""
    echo "To update your backup script:"
    echo "1. Set remote name in config:"
    echo "   config_set \"backup.gdrive_remote\" \"n8n\""
    echo ""
    echo "2. Test backup upload:"
    echo "   rclone copy /some/file n8n:n8n-backups/"
    echo ""
    
    # Create direct fix
    echo "3. Apply direct fix to script:"
    cat << 'EOF'
# Add this to your backup script:
get_gdrive_remote() {
    echo "n8n"
}

has_working_gdrive() {
    rclone lsd n8n: >/dev/null 2>&1
}
EOF

else
    log_error "❌ Google Drive connection failed"
    echo ""
    echo "Recommended fixes:"
    echo "1. Re-run rclone config and recreate remote"
    echo "2. Check internet connectivity"
    echo "3. Verify Google Drive API access"
    echo "4. Try different authentication method"
    echo ""
    echo "Manual fix commands:"
    echo "  rclone config delete n8n"
    echo "  rclone config  # Create new remote"
fi

# Summary
echo ""
echo "================================"
echo "SUMMARY:"
echo "  Remote exists: $(echo "$REMOTES" | grep -q "^n8n:$" && echo "✅" || echo "❌")"
echo "  Connection:    $([[ "$CONNECTION_OK" == "true" ]] && echo "✅" || echo "❌")"
echo "  About API:     $([[ "$ABOUT_OK" == "true" ]] && echo "✅" || echo "❌")"
echo "================================"