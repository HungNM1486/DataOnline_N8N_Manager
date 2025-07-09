#!/bin/bash

# NocoDB Fix Script
# Sửa lỗi database connection và configuration

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

echo -e "${BLUE}🔧 NOCODB FIX SCRIPT${NC}"
echo "===================="

# Step 1: Stop the failing container
echo -e "\n${YELLOW}🛑 Step 1: Stop failing container${NC}"
echo "--------------------------------"

cd "$N8N_COMPOSE_DIR"
echo "Stopping NocoDB container..."
sudo docker compose stop nocodb || true
sudo docker compose rm -f nocodb || true

echo -e "${GREEN}✅ Container stopped${NC}"

# Step 2: Check PostgreSQL and create database if needed
echo -e "\n${YELLOW}🗄️ Step 2: Verify PostgreSQL setup${NC}"
echo "-----------------------------------"

# Check if PostgreSQL is running
if ! sudo docker ps --format '{{.Names}}' | grep -q "postgres"; then
    echo -e "${RED}❌ PostgreSQL not running, starting...${NC}"
    sudo docker compose up -d postgres
    sleep 10
fi

# Get PostgreSQL password
POSTGRES_PASSWORD=$(grep "POSTGRES_PASSWORD=" .env | cut -d'=' -f2)
echo "📊 PostgreSQL password: ${POSTGRES_PASSWORD:0:10}..."

# Test PostgreSQL connection
echo "🔍 Testing PostgreSQL connection..."
if sudo docker exec "$POSTGRES_CONTAINER" pg_isready -U n8n; then
    echo -e "${GREEN}✅ PostgreSQL is ready${NC}"
else
    echo -e "${RED}❌ PostgreSQL connection failed${NC}"
    exit 1
fi

# Check if database exists
echo "🔍 Checking if database 'n8n' exists..."
DB_EXISTS=$(sudo docker exec "$POSTGRES_CONTAINER" psql -U n8n -lqt | cut -d\| -f1 | grep -w n8n | wc -l)

if [[ "$DB_EXISTS" -eq 0 ]]; then
    echo -e "${YELLOW}⚠️ Database 'n8n' not found, creating...${NC}"
    sudo docker exec "$POSTGRES_CONTAINER" createdb -U n8n n8n
    echo -e "${GREEN}✅ Database created${NC}"
else
    echo -e "${GREEN}✅ Database 'n8n' exists${NC}"
fi

# Test database connection
echo "🔍 Testing database connection..."
if sudo docker exec "$POSTGRES_CONTAINER" psql -U n8n -d n8n -c "SELECT 1;" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Database connection successful${NC}"
else
    echo -e "${RED}❌ Database connection failed${NC}"
    exit 1
fi

# Step 3: Fix the database connection string
echo -e "\n${YELLOW}🔧 Step 3: Fix database connection string${NC}"
echo "----------------------------------------"

# Current connection string
echo "📋 Current NC_DB configuration:"
grep "NC_DB=" .env

# Create proper connection string
NEW_CONNECTION_STRING="pg://n8n:${POSTGRES_PASSWORD}@postgres:5432/n8n?sslmode=disable"

echo -e "\n📝 Updating connection string..."
sed -i "s|NC_DB=.*|NC_DB=${NEW_CONNECTION_STRING}|" .env

echo "✅ Updated NC_DB configuration:"
grep "NC_DB=" .env

# Step 4: Update docker-compose.yml for better configuration
echo -e "\n${YELLOW}🐳 Step 4: Update docker-compose configuration${NC}"
echo "----------------------------------------------"

# Create backup
cp docker-compose.yml docker-compose.yml.backup.$(date +%s)

# Update NocoDB environment in docker-compose.yml
cat > /tmp/nocodb_fix.yml << EOF
  nocodb:
    image: nocodb/nocodb:latest
    container_name: n8n-nocodb
    restart: unless-stopped
    environment:
      - NC_DB=${NEW_CONNECTION_STRING}
      - NC_PUBLIC_URL=https://db.n8n-store.xyz
      - NC_AUTH_JWT_SECRET=nB1Kd8ByLZEpmCjEMZqE54idRtNzo8Gq6BF7r2h3NCgfzMb3iCgbkHVtwBlMdvzH
      - NC_ADMIN_EMAIL=admin@n8n-store.xyz
      - NC_ADMIN_PASSWORD=dJvDZe6oRIDLcgFU
      - NC_DISABLE_TELE=true
      - NC_DASHBOARD_URL=/dashboard
      - DATABASE_URL=${NEW_CONNECTION_STRING}
      - NC_TOOL_DIR=/tmp/nc-tool
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
awk '
/^  nocodb:/ {
    system("cat /tmp/nocodb_fix.yml")
    skip = 1
    next
}
/^  [a-zA-Z]/ && skip {
    skip = 0
}
/^[a-zA-Z]/ && skip {
    skip = 0
    print
    next
}
!skip { print }
' docker-compose.yml > /tmp/docker-compose-fixed.yml

mv /tmp/docker-compose-fixed.yml docker-compose.yml
rm -f /tmp/nocodb_fix.yml

echo -e "${GREEN}✅ docker-compose.yml updated${NC}"

# Step 5: Validate configuration
echo -e "\n${YELLOW}✅ Step 5: Validate configuration${NC}"
echo "--------------------------------"

echo "🔍 Validating docker-compose.yml..."
if sudo docker compose config >/dev/null 2>&1; then
    echo -e "${GREEN}✅ docker-compose.yml is valid${NC}"
else
    echo -e "${RED}❌ docker-compose.yml has errors${NC}"
    sudo docker compose config
    exit 1
fi

# Step 6: Start NocoDB with proper wait
echo -e "\n${YELLOW}🚀 Step 6: Start NocoDB${NC}"
echo "----------------------"

echo "🐳 Starting NocoDB container..."
sudo docker compose up -d nocodb

echo "⏳ Waiting for NocoDB to initialize (this may take 2-3 minutes)..."

# Wait function with better logging
wait_for_nocodb() {
    local max_wait=180  # 3 minutes
    local waited=0
    local check_interval=5
    
    while [[ $waited -lt $max_wait ]]; do
        echo -n "."
        
        # Check if container is running
        if ! sudo docker ps --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
            echo -e "\n${RED}❌ Container stopped unexpectedly${NC}"
            echo "📋 Container logs:"
            sudo docker logs --tail 10 "$NOCODB_CONTAINER"
            return 1
        fi
        
        # Check health
        if curl -s -f "http://localhost:8080/api/v1/health" >/dev/null 2>&1; then
            echo -e "\n${GREEN}✅ NocoDB is ready!${NC}"
            return 0
        fi
        
        sleep $check_interval
        ((waited += check_interval))
    done
    
    echo -e "\n${RED}❌ Timeout waiting for NocoDB${NC}"
    return 1
}

if wait_for_nocodb; then
    echo -e "\n${GREEN}🎉 NocoDB started successfully!${NC}"
    
    # Final verification
    echo -e "\n${YELLOW}🔍 Final verification${NC}"
    echo "------------------"
    
    echo "📊 Container status:"
    sudo docker ps --format "table {{.Names}}\t{{.Status}}" | grep nocodb
    
    echo -e "\n🌐 API health check:"
    curl -s "http://localhost:8080/api/v1/health" | head -100
    
    echo -e "\n📋 Access information:"
    echo "🌐 URL: http://103.6.234.189:8080"
    echo "👤 Email: admin@n8n-store.xyz"
    echo "🔑 Password: dJvDZe6oRIDLcgFU"
    
    echo -e "\n${GREEN}✅ NocoDB is ready to use!${NC}"
else
    echo -e "\n${RED}❌ NocoDB failed to start${NC}"
    echo "📋 Debug information:"
    echo "Container status:"
    sudo docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep nocodb
    
    echo -e "\nLast 20 lines of logs:"
    sudo docker logs --tail 20 "$NOCODB_CONTAINER"
    
    echo -e "\n🔧 Manual troubleshooting:"
    echo "1. Check logs: sudo docker logs $NOCODB_CONTAINER"
    echo "2. Restart: sudo docker compose restart nocodb"
    echo "3. Check database: sudo docker exec $POSTGRES_CONTAINER psql -U n8n -d n8n -c 'SELECT 1;'"
    
    exit 1
fi

echo -e "\n${BLUE}🎯 Fix completed!${NC}"