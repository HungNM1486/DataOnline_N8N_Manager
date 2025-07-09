#!/bin/bash

# NocoDB Debug Script
# Phân tích và sửa lỗi cài đặt NocoDB

set -euo pipefail

readonly N8N_COMPOSE_DIR="/opt/n8n"
readonly NOCODB_CONTAINER="n8n-nocodb"
readonly NOCODB_PORT=8080

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

echo -e "${BLUE}🔍 NOCODB DEBUG ANALYSIS${NC}"
echo "=================================="

# Step 1: Check container status
echo -e "\n${YELLOW}📦 Step 1: Container Status${NC}"
echo "----------------------------"

if docker ps -a --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
    container_id=$(docker ps -a -q --filter "name=^${NOCODB_CONTAINER}$")
    container_status=$(docker inspect $container_id --format '{{.State.Status}}')
    
    echo "✅ Container exists: $container_id"
    echo "📊 Status: $container_status"
    echo "🎯 Image: $(docker inspect $container_id --format '{{.Config.Image}}')"
    echo "🕒 Created: $(docker inspect $container_id --format '{{.Created}}' | cut -d'T' -f1)"
    
    if [[ "$container_status" != "running" ]]; then
        echo -e "${RED}❌ Container not running!${NC}"
        exit_code=$(docker inspect $container_id --format '{{.State.ExitCode}}')
        echo "Exit code: $exit_code"
    else
        echo -e "${GREEN}✅ Container is running${NC}"
    fi
else
    echo -e "${RED}❌ NocoDB container not found!${NC}"
    echo "Available containers:"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
    exit 1
fi

# Step 2: Check container logs
echo -e "\n${YELLOW}📝 Step 2: Container Logs${NC}"
echo "-------------------------"

echo "📋 Last 20 lines of NocoDB logs:"
docker logs --tail 20 "$NOCODB_CONTAINER" 2>&1 || echo "No logs available"

echo -e "\n🔍 Checking for error patterns:"
if docker logs "$NOCODB_CONTAINER" 2>&1 | grep -i "error\|exception\|fail" | head -5; then
    echo -e "${RED}❌ Errors found in logs${NC}"
else
    echo -e "${GREEN}✅ No obvious errors in logs${NC}"
fi

# Step 3: Check network connectivity
echo -e "\n${YELLOW}🌐 Step 3: Network Connectivity${NC}"
echo "------------------------------"

echo "📡 Port check:"
if ss -tlpn | grep ":$NOCODB_PORT"; then
    echo -e "${GREEN}✅ Port $NOCODB_PORT is listening${NC}"
else
    echo -e "${RED}❌ Port $NOCODB_PORT not listening${NC}"
fi

echo -e "\n🔗 Container network:"
docker exec "$NOCODB_CONTAINER" ip addr show 2>/dev/null || echo "Cannot get container IP"

echo -e "\n🎯 Health check:"
if docker exec "$NOCODB_CONTAINER" curl -s -f "http://localhost:8080/api/v1/health" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Internal health check passed${NC}"
else
    echo -e "${RED}❌ Internal health check failed${NC}"
fi

# Step 4: Check database connection
echo -e "\n${YELLOW}🗄️ Step 4: Database Connection${NC}"
echo "-----------------------------"

echo "📊 PostgreSQL status:"
if docker ps --format '{{.Names}}' | grep -q "postgres"; then
    echo -e "${GREEN}✅ PostgreSQL container running${NC}"
    
    # Test connection from NocoDB container
    echo "🔗 Testing DB connection from NocoDB:"
    if docker exec "$NOCODB_CONTAINER" nc -z postgres 5432 2>/dev/null; then
        echo -e "${GREEN}✅ Can connect to PostgreSQL${NC}"
    else
        echo -e "${RED}❌ Cannot connect to PostgreSQL${NC}"
    fi
else
    echo -e "${RED}❌ PostgreSQL container not running${NC}"
fi

# Step 5: Check environment variables
echo -e "\n${YELLOW}⚙️ Step 5: Environment Variables${NC}"
echo "-------------------------------"

echo "📋 Key environment variables:"
docker exec "$NOCODB_CONTAINER" printenv | grep -E "^NC_|^DATABASE_URL" | head -10 || echo "Cannot read env vars"

# Step 6: Check resource usage
echo -e "\n${YELLOW}💾 Step 6: Resource Usage${NC}"
echo "-------------------------"

echo "📊 Container resource usage:"
docker stats "$NOCODB_CONTAINER" --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null || echo "Cannot get stats"

echo -e "\n💽 Disk usage:"
df -h /opt/n8n | tail -1

# Step 7: Check docker-compose configuration
echo -e "\n${YELLOW}🐳 Step 7: Docker Compose Check${NC}"
echo "------------------------------"

if [[ -f "$N8N_COMPOSE_DIR/docker-compose.yml" ]]; then
    echo "✅ docker-compose.yml exists"
    
    echo -e "\n📋 NocoDB service configuration:"
    if grep -A 20 "nocodb:" "$N8N_COMPOSE_DIR/docker-compose.yml"; then
        echo -e "${GREEN}✅ NocoDB service found in compose file${NC}"
    else
        echo -e "${RED}❌ NocoDB service not found in compose file${NC}"
    fi
    
    echo -e "\n🔧 Validating compose file:"
    cd "$N8N_COMPOSE_DIR"
    if docker compose config >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Compose file is valid${NC}"
    else
        echo -e "${RED}❌ Compose file has errors${NC}"
        docker compose config
    fi
else
    echo -e "${RED}❌ docker-compose.yml not found${NC}"
fi

# Step 8: Manual health check
echo -e "\n${YELLOW}🩺 Step 8: Manual Health Check${NC}"
echo "-----------------------------"

echo "🎯 Testing NocoDB API manually:"
for i in {1..3}; do
    echo "Attempt $i/3..."
    if curl -s -m 5 "http://localhost:$NOCODB_PORT/api/v1/health" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ NocoDB API responding${NC}"
        break
    else
        echo -e "${RED}❌ NocoDB API not responding${NC}"
        if [[ $i -eq 3 ]]; then
            echo "🔍 Trying with curl verbose:"
            curl -v -m 5 "http://localhost:$NOCODB_PORT/api/v1/health" 2>&1 | head -10
        fi
    fi
    sleep 2
done

# Step 9: Recommendations
echo -e "\n${YELLOW}💡 Step 9: Recommendations${NC}"
echo "-------------------------"

echo "🔧 Troubleshooting actions:"
echo "1. Restart NocoDB container:"
echo "   cd $N8N_COMPOSE_DIR && docker compose restart nocodb"
echo ""
echo "2. Check full logs:"
echo "   docker logs $NOCODB_CONTAINER"
echo ""
echo "3. Restart entire stack:"
echo "   cd $N8N_COMPOSE_DIR && docker compose down && docker compose up -d"
echo ""
echo "4. Check .env file:"
echo "   cat $N8N_COMPOSE_DIR/.env | grep NOCODB"
echo ""
echo "5. Manual container run (debug):"
echo "   docker run -it --rm --name nocodb-debug -p 8080:8080 \\"
echo "     -e NC_DB=pg://n8n:password@host:5432/n8n \\"
echo "     nocodb/nocodb:latest"

echo -e "\n${BLUE}🎯 Debug completed!${NC}"
echo "Check the outputs above and follow the recommendations."