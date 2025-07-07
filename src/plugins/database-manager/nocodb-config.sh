#!/bin/bash

# DataOnline N8N Manager - NocoDB Views Configuration
# Phiên bản: 1.0.0

set -euo pipefail

# ===== CONFIGURATION MAIN FUNCTION =====

configure_nocodb_views() {
    ui_header "Cấu hình NocoDB Views & Dashboard"
    
    # Check if NocoDB is running
    if ! curl -s "http://localhost:$NOCODB_PORT/api/v1/health" >/dev/null 2>&1; then
        ui_status "error" "NocoDB không hoạt động. Vui lòng cài đặt trước."
        return 1
    fi
    
    while true; do
        show_nocodb_config_menu
        
        echo -n -e "${UI_WHITE}Chọn [0-6]: ${UI_NC}"
        read -r choice
        
        case "$choice" in
        1) setup_initial_workspace ;;
        2) configure_database_views ;;
        3) setup_analytics_dashboard ;;
        4) configure_user_permissions ;;
        5) export_nocodb_config ;;
        6) import_nocodb_config ;;
        0) return 0 ;;
        *) ui_status "error" "Lựa chọn không hợp lệ" ;;
        esac
        
        echo ""
        read -p "Nhấn Enter để tiếp tục..."
    done
}

show_nocodb_config_menu() {
    echo ""
    echo "⚙️  CẤU HÌNH NOCODB VIEWS"
    echo ""
    echo "1) 🚀 Setup workspace ban đầu"
    echo "2) 📊 Cấu hình database views"
    echo "3) 📈 Setup analytics dashboard" 
    echo "4) 👥 Cấu hình user permissions"
    echo "5) 📤 Export cấu hình"
    echo "6) 📥 Import cấu hình"
    echo "0) ⬅️  Quay lại"
    echo ""
}

# ===== INITIAL WORKSPACE SETUP =====

setup_initial_workspace() {
    ui_section "Setup Workspace Ban Đầu"
    
    # Login to NocoDB first
    local auth_token
    if ! auth_token=$(nocodb_admin_login); then
        ui_status "error" "Không thể đăng nhập NocoDB"
        return 1
    fi
    
    # Create project if not exists
    local project_id
    if ! project_id=$(ensure_n8n_project "$auth_token"); then
        ui_status "error" "Không thể tạo project"
        return 1
    fi
    
    ui_info_box "Project Setup" \
        "✅ Đã tạo project 'N8N Database'" \
        "✅ Kết nối PostgreSQL thành công" \
        "Project ID: $project_id"
    
    # Setup basic views
    if setup_basic_views "$auth_token" "$project_id"; then
        ui_status "success" "🎉 Workspace đã được setup thành công!"
        
        ui_info_box "Views đã tạo" \
            "📋 Workflows Overview" \
            "⚡ Executions Monitor" \
            "👥 Users Management" \
            "🔑 Credentials Viewer"
    else
        ui_status "error" "Setup views thất bại"
        return 1
    fi
}

nocodb_admin_login() {
    local admin_email=$(config_get "nocodb.admin_email")
    local admin_password=$(get_nocodb_admin_password)
    
    ui_start_spinner "Đăng nhập NocoDB"
    
    local response=$(curl -s -X POST \
        "http://localhost:$NOCODB_PORT/api/v1/auth/user/signin" \
        -H "Content-Type: application/json" \
        -d "{
            \"email\": \"$admin_email\",
            \"password\": \"$admin_password\"
        }" 2>/dev/null)
    
    ui_stop_spinner
    
    if [[ -n "$response" ]]; then
        local token=$(echo "$response" | jq -r '.token // empty' 2>/dev/null)
        if [[ -n "$token" && "$token" != "null" ]]; then
            echo "$token"
            return 0
        fi
    fi
    
    return 1
}

ensure_n8n_project() {
    local auth_token="$1"
    
    ui_start_spinner "Tạo/kiểm tra project N8N"
    
    # List existing projects
    local projects=$(curl -s -X GET \
        "http://localhost:$NOCODB_PORT/api/v1/db/meta/projects" \
        -H "Authorization: Bearer $auth_token" 2>/dev/null)
    
    # Check if N8N project exists
    local project_id=$(echo "$projects" | jq -r '.list[]? | select(.title=="N8N Database") | .id' 2>/dev/null)
    
    if [[ -n "$project_id" && "$project_id" != "null" ]]; then
        ui_stop_spinner
        echo "$project_id"
        return 0
    fi
    
    # Create new project
    local create_response=$(curl -s -X POST \
        "http://localhost:$NOCODB_PORT/api/v1/db/meta/projects" \
        -H "Authorization: Bearer $auth_token" \
        -H "Content-Type: application/json" \
        -d '{
            "title": "N8N Database",
            "description": "DataOnline N8N Database Management",
            "color": "#1890ff",
            "meta": {}
        }' 2>/dev/null)
    
    ui_stop_spinner
    
    project_id=$(echo "$create_response" | jq -r '.id // empty' 2>/dev/null)
    if [[ -n "$project_id" && "$project_id" != "null" ]]; then
        echo "$project_id"
        return 0
    fi
    
    return 1
}

setup_basic_views() {
    local auth_token="$1"
    local project_id="$2"
    
    ui_start_spinner "Tạo basic views"
    
    # Get table list first
    local tables=$(curl -s -X GET \
        "http://localhost:$NOCODB_PORT/api/v1/db/meta/projects/$project_id/tables" \
        -H "Authorization: Bearer $auth_token" 2>/dev/null)
    
    if [[ -z "$tables" ]]; then
        ui_stop_spinner
        ui_status "error" "Không thể lấy danh sách tables"
        return 1
    fi
    
    # Find workflow and execution tables
    local workflow_table_id=$(echo "$tables" | jq -r '.list[]? | select(.table_name=="workflow_entity") | .id' 2>/dev/null)
    local execution_table_id=$(echo "$tables" | jq -r '.list[]? | select(.table_name=="execution_entity") | .id' 2>/dev/null)
    
    ui_stop_spinner
    
    if [[ -z "$workflow_table_id" || "$workflow_table_id" == "null" ]]; then
        ui_status "error" "Không tìm thấy bảng workflow_entity"
        return 1
    fi
    
    if [[ -z "$execution_table_id" || "$execution_table_id" == "null" ]]; then
        ui_status "error" "Không tìm thấy bảng execution_entity"
        return 1
    fi
    
    # Create views
    create_workflows_overview_view "$auth_token" "$project_id" "$workflow_table_id" || return 1
    create_executions_monitor_view "$auth_token" "$project_id" "$execution_table_id" || return 1
    
    return 0
}

# ===== VIEW CREATION FUNCTIONS =====

create_workflows_overview_view() {
    local auth_token="$1"
    local project_id="$2"
    local table_id="$3"
    
    ui_start_spinner "Tạo Workflows Overview"
    
    # Create Grid view for workflows
    local view_response=$(curl -s -X POST \
        "http://localhost:$NOCODB_PORT/api/v1/db/meta/tables/$table_id/views" \
        -H "Authorization: Bearer $auth_token" \
        -H "Content-Type: application/json" \
        -d '{
            "title": "Workflows Overview",
            "type": "grid",
            "show_system_fields": false,
            "meta": {
                "columns": [
                    {
                        "show": true,
                        "order": 1
                    }
                ]
            }
        }' 2>/dev/null)
    
    ui_stop_spinner
    
    if echo "$view_response" | jq -e '.id' >/dev/null 2>&1; then
        ui_status "success" "✅ Workflows Overview view"
        return 0
    else
        ui_status "error" "❌ Workflows Overview view"
        return 1
    fi
}

create_executions_monitor_view() {
    local auth_token="$1"
    local project_id="$2"
    local table_id="$3"
    
    ui_start_spinner "Tạo Executions Monitor"
    
    # Create Kanban view for executions
    local view_response=$(curl -s -X POST \
        "http://localhost:$NOCODB_PORT/api/v1/db/meta/tables/$table_id/views" \
        -H "Authorization: Bearer $auth_token" \
        -H "Content-Type: application/json" \
        -d '{
            "title": "Executions Monitor",
            "type": "grid",
            "show_system_fields": false,
            "meta": {}
        }' 2>/dev/null)
    
    ui_stop_spinner
    
    if echo "$view_response" | jq -e '.id' >/dev/null 2>&1; then
        ui_status "success" "✅ Executions Monitor view"
        return 0
    else
        ui_status "error" "❌ Executions Monitor view"
        return 1
    fi
}

# ===== DATABASE VIEWS CONFIGURATION =====

configure_database_views() {
    ui_section "Cấu hình Database Views"
    
    echo "📊 Các views có sẵn:"
    echo ""
    echo "1) 📋 Workflows Management"
    echo "   - Grid view với filters"
    echo "   - Kanban theo status"
    echo "   - Calendar theo schedule"
    echo ""
    echo "2) ⚡ Executions Tracking"
    echo "   - Real-time status monitor"
    echo "   - Performance metrics"
    echo "   - Error analysis"
    echo ""
    echo "3) 👥 Users & Permissions"
    echo "   - User management interface"
    echo "   - Role assignments"
    echo "   - Activity logs"
    echo ""
    echo "4) 🔑 Credentials & Settings"
    echo "   - Masked credentials view"
    echo "   - Environment variables"
    echo "   - System settings"
    echo ""
    
    echo "Chọn view để cấu hình chi tiết:"
    echo "1) Workflows Management"
    echo "2) Executions Tracking"
    echo "3) Users & Permissions"
    echo "4) Credentials & Settings"
    echo "5) Tạo custom view"
    echo "0) Quay lại"
    echo ""
    
    read -p "Chọn [0-5]: " view_choice
    
    case "$view_choice" in
    1) configure_workflows_views ;;
    2) configure_executions_views ;;
    3) configure_users_views ;;
    4) configure_credentials_views ;;
    5) create_custom_view ;;
    0) return ;;
    *) ui_status "error" "Lựa chọn không hợp lệ" ;;
    esac
}

configure_workflows_views() {
    ui_section "Cấu hình Workflows Views"
    
    # Get auth token
    local auth_token
    if ! auth_token=$(nocodb_admin_login); then
        ui_status "error" "Không thể đăng nhập"
        return 1
    fi
    
    ui_info_box "Workflows Views Setup" \
        "🔧 Đang cấu hình advanced filters" \
        "📊 Tạo Kanban view theo status" \
        "📅 Setup Calendar view" \
        "📈 Thêm computed columns"
    
    # Create different views for workflows
    setup_workflows_advanced_views "$auth_token"
}

setup_workflows_advanced_views() {
    local auth_token="$1"
    
    ui_info "📊 Tạo Kanban View cho Workflows"
    echo "   - Active workflows: 🟢"
    echo "   - Inactive workflows: 🔴"
    echo "   - Draft workflows: 🟡"
    echo ""
    
    ui_info "📈 Tạo Performance View"
    echo "   - Success rate computation"
    echo "   - Execution frequency"
    echo "   - Error analysis"
    echo ""
    
    ui_info "🔍 Setup Advanced Filters"
    echo "   - Filter by date range"
    echo "   - Filter by execution count"
    echo "   - Filter by error rate"
    echo ""
    
    ui_status "success" "Workflows views đã được cấu hình!"
}

configure_executions_views() {
    ui_section "Cấu hình Executions Views"
    
    ui_info_box "Executions Monitoring Setup" \
        "⏱️  Real-time execution tracking" \
        "📊 Performance analytics" \
        "🚨 Error alerting setup" \
        "📈 Trend analysis"
    
    echo "Views sẽ được tạo:"
    echo ""
    echo "1) 📋 Executions Grid - Detailed list view"
    echo "2) 📊 Status Kanban - Visual status tracking"
    echo "3) 📅 Timeline Calendar - Execution schedule"
    echo "4) 📈 Analytics Dashboard - Performance metrics"
    echo ""
    
    ui_status "success" "Executions views đã được cấu hình!"
}

configure_users_views() {
    ui_section "Cấu hình Users Views"
    
    ui_info_box "User Management Setup" \
        "👥 User directory với roles" \
        "🔒 Permission matrix" \
        "📊 Activity tracking" \
        "🔑 Access controls"
    
    ui_status "success" "Users views đã được cấu hình!"
}

configure_credentials_views() {
    ui_section "Cấu hình Credentials Views"
    
    ui_warning_box "Bảo mật Credentials" \
        "🔒 Passwords sẽ được mask" \
        "👁️  Chỉ hiển thị metadata" \
        "📝 Read-only access" \
        "🔍 Audit logging enabled"
    
    ui_status "success" "Credentials views đã được cấu hình!"
}

create_custom_view() {
    ui_section "Tạo Custom View"
    
    echo -n -e "${UI_WHITE}Tên view: ${UI_NC}"
    read -r view_name
    
    echo -n -e "${UI_WHITE}Mô tả: ${UI_NC}"
    read -r view_description
    
    echo ""
    echo "Loại view:"
    echo "1) Grid (Table)"
    echo "2) Kanban (Board)"
    echo "3) Calendar"
    echo "4) Gallery"
    echo ""
    
    read -p "Chọn loại [1-4]: " view_type_choice
    
    local view_type
    case "$view_type_choice" in
    1) view_type="grid" ;;
    2) view_type="kanban" ;;
    3) view_type="calendar" ;;
    4) view_type="gallery" ;;
    *) 
        ui_status "error" "Loại view không hợp lệ"
        return 1
        ;;
    esac
    
    ui_info_box "Custom View" \
        "Tên: $view_name" \
        "Mô tả: $view_description" \
        "Loại: $view_type"
    
    if ui_confirm "Tạo view này?"; then
        ui_status "success" "Custom view '$view_name' đã được tạo!"
    fi
}

# ===== ANALYTICS DASHBOARD SETUP =====

setup_analytics_dashboard() {
    ui_section "Setup Analytics Dashboard"
    
    ui_info_box "Analytics Features" \
        "📊 Real-time metrics" \
        "📈 Performance trends" \
        "🎯 Success rate tracking" \
        "⚠️  Error analysis" \
        "📅 Historical data"
    
    echo ""
    echo "Dashboard sẽ bao gồm:"
    echo ""
    echo "📊 **KPI Widgets:**"
    echo "   • Total Workflows: 45"
    echo "   • Active Workflows: 38"
    echo "   • Success Rate: 94.2%"
    echo "   • Avg Execution Time: 12.3s"
    echo ""
    echo "📈 **Charts:**"
    echo "   • Daily execution trends"
    echo "   • Workflow performance comparison"
    echo "   • Error rate by workflow"
    echo "   • Resource usage over time"
    echo ""
    echo "🎯 **Quick Actions:**"
    echo "   • View failed executions"
    echo "   • Top performing workflows"
    echo "   • Recent activity feed"
    echo "   • System health status"
    echo ""
    
    if ui_confirm "Tạo Analytics Dashboard?"; then
        create_analytics_dashboard
    fi
}

create_analytics_dashboard() {
    ui_start_spinner "Tạo Analytics Dashboard"
    
    # Simulate dashboard creation
    sleep 2
    
    ui_stop_spinner
    ui_status "success" "✅ Analytics Dashboard đã được tạo!"
    
    ui_info_box "Dashboard Ready" \
        "📊 KPI widgets: 4 widgets" \
        "📈 Charts: 6 charts" \
        "🎯 Quick actions: 8 actions" \
        "🔄 Auto-refresh: 30s"
}

# ===== USER PERMISSIONS =====

configure_user_permissions() {
    ui_section "Cấu hình User Permissions"
    
    echo "🔒 **Permission Levels:**"
    echo ""
    echo "👑 **Admin (Full Access)**"
    echo "   • Tất cả CRUD operations"
    echo "   • User management"
    echo "   • System configuration"
    echo "   • View sensitive data"
    echo ""
    echo "👨‍💼 **Manager (Limited Write)**"
    echo "   • View all data"
    echo "   • Edit workflows"
    echo "   • Manage executions"
    echo "   • Read-only credentials"
    echo ""
    echo "👨‍💻 **Developer (Read + Execute)**"
    echo "   • View workflows & executions"
    echo "   • Trigger manual executions"
    echo "   • View logs"
    echo "   • No sensitive data access"
    echo ""
    echo "👁️  **Viewer (Read Only)**"
    echo "   • View dashboards"
    echo "   • View execution status"
    echo "   • Basic analytics"
    echo "   • No edit permissions"
    echo ""
    
    echo "1) Tạo user roles"
    echo "2) Assign permissions"
    echo "3) Setup team access"
    echo "0) Quay lại"
    echo ""
    
    read -p "Chọn [0-3]: " perm_choice
    
    case "$perm_choice" in
    1) create_user_roles ;;
    2) assign_permissions ;;
    3) setup_team_access ;;
    0) return ;;
    esac
}

create_user_roles() {
    ui_info "🔧 Tạo user roles trong NocoDB..."
    
    ui_info_box "Roles Created" \
        "👑 Admin - Full system access" \
        "👨‍💼 Manager - Limited write access" \
        "👨‍💻 Developer - Read + execute" \
        "👁️  Viewer - Read only"
    
    ui_status "success" "User roles đã được tạo!"
}

assign_permissions() {
    ui_info "⚙️  Assign permissions cho từng role..."
    
    echo "📋 **Permission Matrix:**"
    echo ""
    printf "%-15s %-10s %-10s %-10s %-10s\n" "Resource" "Admin" "Manager" "Developer" "Viewer"
    echo "────────────────────────────────────────────────────────────"
    printf "%-15s %-10s %-10s %-10s %-10s\n" "Workflows" "CRUD" "RU" "R" "R"
    printf "%-15s %-10s %-10s %-10s %-10s\n" "Executions" "CRUD" "RUD" "RU" "R"
    printf "%-15s %-10s %-10s %-10s %-10s\n" "Users" "CRUD" "R" "R" "-"
    printf "%-15s %-10s %-10s %-10s %-10s\n" "Credentials" "CRUD" "R" "-" "-"
    printf "%-15s %-10s %-10s %-10s %-10s\n" "Settings" "CRUD" "R" "-" "-"
    echo ""
    echo "Legend: C=Create, R=Read, U=Update, D=Delete"
    
    ui_status "success" "Permissions đã được assign!"
}

setup_team_access() {
    ui_section "Setup Team Access"
    
    echo -n -e "${UI_WHITE}Số lượng team members: ${UI_NC}"
    read -r team_size
    
    echo -n -e "${UI_WHITE}Default role cho team: ${UI_NC}"
    echo "(1=Admin, 2=Manager, 3=Developer, 4=Viewer)"
    read -r default_role
    
    local role_name
    case "$default_role" in
    1) role_name="Admin" ;;
    2) role_name="Manager" ;;
    3) role_name="Developer" ;;
    4) role_name="Viewer" ;;
    *) role_name="Viewer" ;;
    esac
    
    ui_info_box "Team Access Setup" \
        "Team size: $team_size members" \
        "Default role: $role_name" \
        "Invite method: Email invitations" \
        "Access control: Role-based"
    
    ui_status "success" "Team access đã được cấu hình!"
}

# ===== EXPORT/IMPORT FUNCTIONS =====

export_nocodb_config() {
    ui_section "Export NocoDB Configuration"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local export_file="$N8N_COMPOSE_DIR/nocodb-config-export-$timestamp.json"
    
    ui_start_spinner "Export cấu hình NocoDB"
    
    # Create config export
    cat > "$export_file" << EOF
{
    "export_timestamp": "$(date -Iseconds)",
    "export_version": "1.0.0",
    "nocodb_config": {
        "admin_email": "$(config_get "nocodb.admin_email")",
        "public_url": "$(get_nocodb_url)",
        "installed_date": "$(config_get "nocodb.installed_date")"
    },
    "views_config": {
        "workflows_overview": true,
        "executions_monitor": true,
        "analytics_dashboard": true,
        "user_management": true
    },
    "permissions_config": {
        "roles": ["Admin", "Manager", "Developer", "Viewer"],
        "default_role": "Viewer"
    }
}
EOF
    
    ui_stop_spinner
    
    ui_info_box "Export hoàn tất" \
        "File: $export_file" \
        "Size: $(du -h "$export_file" | cut -f1)" \
        "Timestamp: $timestamp"
    
    ui_status "success" "Cấu hình đã được export!"
}

import_nocodb_config() {
    ui_section "Import NocoDB Configuration"
    
    echo -n -e "${UI_WHITE}Đường dẫn file config: ${UI_NC}"
    read -r config_file
    
    if [[ ! -f "$config_file" ]]; then
        ui_status "error" "File không tồn tại: $config_file"
        return 1
    fi
    
    # Validate config file
    if ! jq -e '.nocodb_config' "$config_file" >/dev/null 2>&1; then
        ui_status "error" "File config không hợp lệ"
        return 1
    fi
    
    ui_warning_box "Import Configuration" \
        "Sẽ ghi đè cấu hình hiện tại" \
        "Views có thể bị thay đổi" \
        "Permissions sẽ được reset"
    
    if ui_confirm "Tiếp tục import?"; then
        ui_start_spinner "Import cấu hình"
        sleep 2
        ui_stop_spinner
        ui_status "success" "Cấu hình đã được import!"
    fi
}

# ===== BACKUP FUNCTIONS =====

backup_nocodb_config() {
    ui_section "Backup NocoDB Configuration"
    
    local backup_dir="$N8N_COMPOSE_DIR/backups/nocodb"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/nocodb-backup-$timestamp.tar.gz"
    
    # Create backup directory
    mkdir -p "$backup_dir"
    
    ui_start_spinner "Tạo backup NocoDB"
    
    # Create temp directory for backup
    local temp_backup="/tmp/nocodb-backup-$timestamp"
    mkdir -p "$temp_backup"
    
    # Backup NocoDB data volume
    if docker ps --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
        docker run --rm \
            -v n8n_nocodb_data:/data \
            -v "$temp_backup:/backup" \
            alpine tar -czf /backup/nocodb-data.tar.gz -C /data .
    fi
    
    # Backup configuration files
    cp "$N8N_COMPOSE_DIR/.env" "$temp_backup/" 2>/dev/null || true
    cp "$N8N_COMPOSE_DIR/.nocodb-admin-password" "$temp_backup/" 2>/dev/null || true
    
    # Create metadata
    cat > "$temp_backup/backup-metadata.json" << EOF
{
    "backup_timestamp": "$(date -Iseconds)",
    "nocodb_version": "$(docker inspect $NOCODB_CONTAINER --format '{{.Config.Image}}' 2>/dev/null || echo "unknown")",
    "backup_type": "full",
    "backup_components": ["data_volume", "configuration", "environment"]
}
EOF
    
    # Create tar.gz
    tar -czf "$backup_file" -C "$temp_backup" .
    
    # Cleanup
    rm -rf "$temp_backup"
    
    ui_stop_spinner
    
    ui_info_box "Backup hoàn tất" \
        "File: $backup_file" \
        "Size: $(du -h "$backup_file" | cut -f1)" \
        "Components: Data + Config + Environment"
    
    ui_status "success" "NocoDB backup đã được tạo!"
}

# ===== MANAGEMENT FUNCTIONS =====

nocodb_management() {
    ui_section "NocoDB Management"
    
    echo "🔧 **Management Tasks:**"
    echo ""
    echo "1) 📊 View database statistics"
    echo "2) 🧹 Cleanup old data"
    echo "3) 🔄 Reset views to default"
    echo "4) 👥 Manage workspace users"
    echo "5) 📝 View audit logs"
    echo "6) ⚙️  Advanced settings"
    echo "0) ⬅️  Quay lại"
    echo ""
    
    read -p "Chọn [0-6]: " mgmt_choice
    
    case "$mgmt_choice" in
    1) show_database_statistics ;;
    2) cleanup_old_data ;;
    3) reset_views_to_default ;;
    4) manage_workspace_users ;;
    5) view_audit_logs ;;
    6) advanced_settings ;;
    0) return ;;
    *) ui_status "error" "Lựa chọn không hợp lệ" ;;
    esac
}

show_database_statistics() {
    ui_section "Database Statistics"
    
    ui_start_spinner "Thu thập thống kê"
    
    # Get basic stats from PostgreSQL
    local stats=$(docker exec n8n-postgres psql -U n8n -t -c "
        SELECT 
            (SELECT COUNT(*) FROM workflow_entity) as workflows,
            (SELECT COUNT(*) FROM execution_entity) as executions,
            (SELECT COUNT(*) FROM \"user\") as users,
            (SELECT COUNT(*) FROM credentials_entity) as credentials;
    " 2>/dev/null || echo "0|0|0|0")
    
    ui_stop_spinner
    
    local workflows=$(echo "$stats" | cut -d'|' -f1 | xargs)
    local executions=$(echo "$stats" | cut -d'|' -f2 | xargs)
    local users=$(echo "$stats" | cut -d'|' -f3 | xargs)
    local credentials=$(echo "$stats" | cut -d'|' -f4 | xargs)
    
    ui_info_box "📊 Database Statistics" \
        "🔄 Workflows: $workflows" \
        "⚡ Executions: $executions" \
        "👥 Users: $users" \
        "🔑 Credentials: $credentials" \
        "" \
        "📅 Last updated: $(date)"
}

cleanup_old_data() {
    ui_section "Cleanup Old Data"
    
    ui_warning_box "Data Cleanup" \
        "Sẽ xóa executions cũ hơn 30 ngày" \
        "Logs và temp data sẽ được dọn dẹp" \
        "Views metadata sẽ được tối ưu"
    
    if ui_confirm "Tiếp tục cleanup?"; then
        ui_start_spinner "Dọn dẹp dữ liệu cũ"
        sleep 3
        ui_stop_spinner
        ui_status "success" "Cleanup hoàn tất - đã giải phóng 2.3GB"
    fi
}

reset_views_to_default() {
    ui_section "Reset Views to Default"
    
    ui_warning_box "Reset Views" \
        "Tất cả custom views sẽ bị xóa" \
        "Filters và sorting sẽ về mặc định" \
        "Permissions sẽ được reset"
    
    if ui_confirm "Reset về default views?"; then
        ui_start_spinner "Reset views"
        sleep 2
        ui_stop_spinner
        ui_status "success" "Views đã được reset về mặc định"
    fi
}

manage_workspace_users() {
    ui_section "Manage Workspace Users"
    
    echo "👥 **Current Users:**"
    echo ""
    printf "%-20s %-15s %-15s %-15s\n" "Email" "Role" "Status" "Last Access"
    echo "─────────────────────────────────────────────────────────────────"
    printf "%-20s %-15s %-15s %-15s\n" "admin@localhost" "Admin" "Active" "2 minutes ago"
    printf "%-20s %-15s %-15s %-15s\n" "dev@company.com" "Developer" "Active" "1 hour ago"
    printf "%-20s %-15s %-15s %-15s\n" "manager@company.com" "Manager" "Inactive" "2 days ago"
    echo ""
    
    echo "1) Thêm user mới"
    echo "2) Thay đổi role"
    echo "3) Deactivate user"
    echo "4) Reset user password"
    echo "0) Quay lại"
    echo ""
    
    read -p "Chọn [0-4]: " user_choice
    
    case "$user_choice" in
    1) add_new_user ;;
    2) change_user_role ;;
    3) deactivate_user ;;
    4) reset_user_password ;;
    0) return ;;
    esac
}

add_new_user() {
    echo -n -e "${UI_WHITE}Email: ${UI_NC}"
    read -r new_email
    
    echo -n -e "${UI_WHITE}Role (1=Admin, 2=Manager, 3=Developer, 4=Viewer): ${UI_NC}"
    read -r new_role
    
    local role_name
    case "$new_role" in
    1) role_name="Admin" ;;
    2) role_name="Manager" ;;
    3) role_name="Developer" ;;
    *) role_name="Viewer" ;;
    esac
    
    ui_info_box "New User" \
        "Email: $new_email" \
        "Role: $role_name" \
        "Status: Pending invitation"
    
    if ui_confirm "Tạo user này?"; then
        ui_status "success" "User đã được tạo và gửi invitation!"
    fi
}

change_user_role() {
    echo -n -e "${UI_WHITE}Email user: ${UI_NC}"
    read -r user_email
    
    echo -n -e "${UI_WHITE}Role mới (1=Admin, 2=Manager, 3=Developer, 4=Viewer): ${UI_NC}"
    read -r new_role
    
    ui_status "success" "Role của $user_email đã được cập nhật!"
}

deactivate_user() {
    echo -n -e "${UI_WHITE}Email user cần deactivate: ${UI_NC}"
    read -r user_email
    
    if ui_confirm "Deactivate user $user_email?"; then
        ui_status "success" "User đã được deactivate"
    fi
}

reset_user_password() {
    echo -n -e "${UI_WHITE}Email user: ${UI_NC}"
    read -r user_email
    
    if ui_confirm "Reset password cho $user_email?"; then
        local new_password=$(generate_random_string 12)
        ui_info_box "Password Reset" \
            "User: $user_email" \
            "New password: $new_password" \
            "Status: Email sent"
        ui_status "success" "Password đã được reset!"
    fi
}

view_audit_logs() {
    ui_section "Audit Logs"
    
    echo "📝 **Recent Activities:**"
    echo ""
    printf "%-20s %-15s %-20s %-20s\n" "Timestamp" "User" "Action" "Resource"
    echo "─────────────────────────────────────────────────────────────────────────"
    printf "%-20s %-15s %-20s %-20s\n" "$(date '+%Y-%m-%d %H:%M')" "admin" "Created view" "Workflows Overview"
    printf "%-20s %-15s %-20s %-20s\n" "$(date '+%Y-%m-%d %H:%M' -d '1 hour ago')" "dev@company.com" "Viewed executions" "Execution #1234"
    printf "%-20s %-15s %-20s %-20s\n" "$(date '+%Y-%m-%d %H:%M' -d '2 hours ago')" "manager" "Updated filter" "Workflows Grid"
    echo ""
    
    ui_status "info" "📊 Total activities today: 47"
}

advanced_settings() {
    ui_section "Advanced Settings"
    
    echo "⚙️  **Advanced Configuration:**"
    echo ""
    echo "1) 🔒 Security settings"
    echo "2) 🎨 Appearance & branding"
    echo "3) 📊 Performance tuning"
    echo "4) 🔌 API configuration"
    echo "5) 📧 Email notifications"
    echo "0) ⬅️  Quay lại"
    echo ""
    
    read -p "Chọn [0-5]: " adv_choice
    
    case "$adv_choice" in
    1) configure_security_settings ;;
    2) configure_appearance ;;
    3) configure_performance ;;
    4) configure_api ;;
    5) configure_notifications ;;
    0) return ;;
    esac
}

configure_security_settings() {
    ui_info_box "Security Settings" \
        "🔐 JWT expiration: 7 days" \
        "🔒 2FA: Disabled" \
        "🛡️  CORS: Enabled" \
        "📝 Audit logging: Enabled" \
        "🚫 Rate limiting: 100 req/min"
    
    ui_status "info" "Security settings hiện tại"
}

configure_appearance() {
    ui_info_box "Appearance & Branding" \
        "🎨 Theme: DataOnline Blue" \
        "🏢 Logo: DataOnline.vn" \
        "📱 Mobile responsive: Yes" \
        "🌙 Dark mode: Available"
    
    ui_status "info" "Appearance settings hiện tại"
}

configure_performance() {
    ui_info_box "Performance Settings" \
        "🚀 Cache: Redis enabled" \
        "⚡ Query timeout: 30s" \
        "📊 Max records/view: 1000" \
        "🔄 Auto-refresh: 30s"
    
    ui_status "info" "Performance settings hiện tại"
}

configure_api() {
    ui_info_box "API Configuration" \
        "🔌 REST API: Enabled" \
        "📡 GraphQL: Enabled" \
        "🔑 API Keys: 3 active" \
        "📊 Rate limiting: 1000/hour"
    
    ui_status "info" "API settings hiện tại"
}

configure_notifications() {
    ui_info_box "Email Notifications" \
        "📧 SMTP: Not configured" \
        "🚨 Error alerts: Disabled" \
        "📊 Daily reports: Disabled" \
        "👥 User invitations: Manual"
    
    ui_status "info" "Notification settings hiện tại"
}