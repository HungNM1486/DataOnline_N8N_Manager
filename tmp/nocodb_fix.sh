#!/bin/bash

# NocoDB Fix Script - Environment Variables Approach
# Sửa lỗi "Meta database configuration missing database name"

set -euo pipefail

readonly N8N_COMPOSE_DIR="/opt/n8n"
readonly NOCODB_CONTAINER="n8n-nocodb"
readonly POSTGRES_CONTAINER="n8n-postgres"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

echo -e "${BLUE}🔧 NOCODB FIX SCRIPT - Environment Variables Approach${NC}"
echo "================================================================"

# Function to log with timestamp
log_info() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] INFO:${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SUCCESS:${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $1"
}

# Step 1: Stop failing container
log_info "Step 1: Stopping failing NocoDB container"
echo "================================================"

cd "$N8N_COMPOSE_DIR" || exit 1

log_info "Stopping NocoDB container..."
sudo docker compose stop nocodb 2>/dev/null || true
sudo docker compose rm -f nocodb 2>/dev/null || true

log_success "Container stopped and removed"

# Step 2: Get database credentials
log_info "Step 2: Getting database credentials"
echo "===================================="

if [[ ! -f ".env" ]]; then
    log_error ".env file not found in $N8N_COMPOSE_DIR"
    exit 1
fi

# Source .env file to get variables
set -a
source .env
set +a

log_info "Database credentials loaded from .env"
echo "  Database: n8n"
echo "  Host: postgres"
echo "  Port: 5432"
echo "  User: n8n"
echo "  Password: ${POSTGRES_PASSWORD:0:8}..."

# Step 3: Test PostgreSQL connection
log_info "Step 3: Testing PostgreSQL connection"
echo "===================================="

# Start PostgreSQL if not running
if ! sudo docker ps --format '{{.Names}}' | grep -q "postgres"; then
    log_warning "PostgreSQL not running, starting..."
    sudo docker compose up -d postgres
    sleep 10
fi

# Test connection
log_info "Testing PostgreSQL connection..."
if sudo docker exec "$POSTGRES_CONTAINER" pg_isready -U n8n; then
    log_success "PostgreSQL is ready"
else
    log_error "PostgreSQL not ready"
    exit 1
fi

# Ensure database exists
log_info "Checking database 'n8n'..."
DB_EXISTS=$(sudo docker exec "$POSTGRES_CONTAINER" psql -U n8n -lqt | cut -d\| -f1 | grep -w n8n | wc -l)

if [[ "$DB_EXISTS" -eq 0 ]]; then
    log_warning "Database 'n8n' not found, creating..."
    sudo docker exec "$POSTGRES_CONTAINER" createdb -U n8n n8n
    log_success "Database 'n8n' created"
else
    log_success "Database 'n8n' exists"
fi

# Step 4: Create backup of docker-compose.yml
log_info "Step 4: Backing up docker-compose.yml"
echo "====================================="

cp docker-compose.yml docker-compose.yml.backup.$(date +%s)
log_success "Backup created"

# Step 5: Update docker-compose.yml with separate environment variables
log_info "Step 5: Updating docker-compose.yml with separate env vars"
echo "========================================================"

# Create new NocoDB service configuration
cat > /tmp/nocodb_service_fixed.yml << EOF
  nocodb:
    image: nocodb/nocodb:latest
    container_name: n8n-nocodb
    restart: unless-stopped
    environment:
      # Database connection using separate variables
      - NC_DB_TYPE=pg
      - NC_DB_HOST=postgres
      - NC_DB_PORT=5432
      - NC_DB_USER=n8n
      - NC_DB_PASSWORD=${POSTGRES_PASSWORD}
      - NC_DB_DATABASE=n8n
      - NC_DB_SSL=false
      
      # Alternative: Use full connection string with proper escaping
      # - NC_DB=postgresql://n8n:${POSTGRES_PASSWORD}@postgres:5432/n8n?sslmode=disable
      
      # NocoDB configuration
      - NC_PUBLIC_URL=${NOCODB_PUBLIC_URL:-https://db.n8n-store.xyz}
      - NC_AUTH_JWT_SECRET=${NOCODB_JWT_SECRET}
      - NC_ADMIN_EMAIL=${NOCODB_ADMIN_EMAIL}
      - NC_ADMIN_PASSWORD=${NOCODB_ADMIN_PASSWORD}
      - NC_DISABLE_TELE=true
      - NC_DASHBOARD_URL=/dashboard
      
      # Additional configuration
      - NC_TOOL_DIR=/tmp/nc-tool
      - NC_MIN_DB_POOL_SIZE=1
      - NC_MAX_DB_POOL_SIZE=10
      - NC_DB_MIGRATE=true
      - NC_DB_MIGRATE_LOCK=true
      
      # Logging
      - NC_LOG_LEVEL=info
      - NODE_ENV=production
      
    ports:
      - "8080:8080"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - nocodb_data:/usr/app/data
      - ./nocodb-config:/usr/app/config
    networks:
      - n8n-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/v1/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
EOF

# Replace NocoDB service in docker-compose.yml
log_info "Replacing NocoDB service in docker-compose.yml..."

# Create temporary file with updated service
awk '
BEGIN { in_nocodb = 0; skip_lines = 0 }
/^  nocodb:/ { 
    in_nocodb = 1
    system("cat /tmp/nocodb_service_fixed.yml")
    next
}
/^  [a-zA-Z]/ && in_nocodb { 
    in_nocodb = 0
    print
    next
}
/^[a-zA-Z]/ && in_nocodb { 
    in_nocodb = 0
    print
    next
}
!in_nocodb { print }
' docker-compose.yml > /tmp/docker-compose-fixed.yml

# Validate the new compose file
log_info "Validating docker-compose.yml..."
if sudo docker compose -f /tmp/docker-compose-fixed.yml config >/dev/null 2>&1; then
    mv /tmp/docker-compose-fixed.yml docker-compose.yml
    log_success "docker-compose.yml updated successfully"
else
    log_error "docker-compose.yml validation failed"
    sudo docker compose -f /tmp/docker-compose-fixed.yml config
    exit 1
fi

# Cleanup temp files
rm -f /tmp/nocodb_service_fixed.yml /tmp/docker-compose-fixed.yml

# Step 6: Update .env file if needed
log_info "Step 6: Updating .env file"
echo "========================="

# Add NocoDB specific environment variables if not present
if ! grep -q "NC_DB_TYPE" .env; then
    log_info "Adding NocoDB database environment variables to .env..."
    cat >> .env << EOF

# NocoDB Database Configuration - Separate Variables
NC_DB_TYPE=pg
NC_DB_HOST=postgres
NC_DB_PORT=5432
NC_DB_USER=n8n
NC_DB_DATABASE=n8n
NC_DB_SSL=false
NC_DB_MIGRATE=true
NC_DB_MIGRATE_LOCK=true
NC_MIN_DB_POOL_SIZE=1
NC_MAX_DB_POOL_SIZE=10
EOF
    log_success "Environment variables added to .env"
fi

# Step 7: Create nocodb-config directory
log_info "Step 7: Creating nocodb-config directory"
echo "======================================="

mkdir -p nocodb-config
log_success "nocodb-config directory created"

# Step 8: Start NocoDB with proper configuration
log_info "Step 8: Starting NocoDB with new configuration"
echo "============================================="

log_info "Starting NocoDB container..."
sudo docker compose up -d nocodb

# Step 9: Wait for NocoDB to initialize
log_info "Step 9: Waiting for NocoDB to initialize"
echo "========================================"

wait_for_nocodb() {
    local max_wait=300  # 5 minutes
    local waited=0
    local check_interval=10
    
    log_info "Waiting for NocoDB to start (max ${max_wait}s)..."
    
    while [[ $waited -lt $max_wait ]]; do
        # Check if container is running
        if ! sudo docker ps --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
            log_error "Container stopped unexpectedly!"
            echo "Recent logs:"
            sudo docker logs --tail 10 "$NOCODB_CONTAINER"
            return 1
        fi
        
        # Check container health
        container_health=$(sudo docker inspect "$NOCODB_CONTAINER" --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
        container_status=$(sudo docker inspect "$NOCODB_CONTAINER" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
        
        echo -n "  Status: $container_status"
        if [[ "$container_health" != "none" ]]; then
            echo " | Health: $container_health"
        else
            echo ""
        fi
        
        # Check API health
        if curl -s -f "http://localhost:8080/api/v1/health" >/dev/null 2>&1; then
            log_success "NocoDB API is responding!"
            return 0
        fi
        
        sleep $check_interval
        ((waited += check_interval))
    done
    
    log_error "Timeout waiting for NocoDB to start"
    return 1
}

if wait_for_nocodb; then
    log_success "NocoDB started successfully!"
    
    # Step 10: Final verification
    log_info "Step 10: Final verification"
    echo "========================="
    
    echo "📊 Container status:"
    sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAMES|nocodb)"
    
    echo ""
    echo "🌐 API response:"
    curl -s "http://localhost:8080/api/v1/health" | head -100 || echo "API not responding"
    
    echo ""
    echo "📋 Access information:"
    echo "  🌐 URL: http://$(curl -s ifconfig.me):8080"
    echo "  👤 Email: ${NOCODB_ADMIN_EMAIL}"
    echo "  🔑 Password: ${NOCODB_ADMIN_PASSWORD}"
    
    echo ""
    log_success "🎉 NocoDB is ready to use!"
    
    # Show some useful commands
    echo ""
    echo "📝 Useful commands:"
    echo "  Check logs: sudo docker logs n8n-nocodb"
    echo "  Restart: sudo docker compose restart nocodb"
    echo "  Stop: sudo docker compose stop nocodb"
    echo "  Check health: curl http://localhost:8080/api/v1/health"
    
else
    log_error "NocoDB failed to start properly"
    
    echo ""
    echo "🔍 Debug information:"
    echo "===================="
    
    # Container status
    echo "Container status:"
    sudo docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAMES|nocodb)"
    
    # Recent logs
    echo ""
    echo "Recent logs (last 30 lines):"
    sudo docker logs --tail 30 "$NOCODB_CONTAINER"
    
    # Environment check
    echo ""
    echo "Environment variables check:"
    sudo docker exec "$NOCODB_CONTAINER" printenv | grep -E "^NC_|^NODE_" | head -10 || echo "Cannot read env vars"
    
    echo ""
    echo "🔧 Next steps:"
    echo "1. Check logs: sudo docker logs n8n-nocodb"
    echo "2. Check database: sudo docker exec n8n-postgres psql -U n8n -d n8n -c 'SELECT 1;'"
    echo "3. Restart: sudo docker compose restart nocodb"
    echo "4. Check network: sudo docker exec n8n-nocodb ping postgres"
    
    exit 1
fi

echo ""
echo -e "${BLUE}🎯 Fix completed successfully!${NC}"
echo "NocoDB is now running with separate environment variables approach."