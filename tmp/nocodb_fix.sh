#!/bin/bash

# NocoDB Email Fix Script
# Sửa lỗi invalid admin email

set -euo pipefail

readonly N8N_COMPOSE_DIR="/opt/n8n"

echo "🔧 Fixing NocoDB admin email issue..."

# Stop failing container
echo "Stopping NocoDB container..."
cd "$N8N_COMPOSE_DIR"
docker compose stop nocodb 2>/dev/null || true
docker compose rm -f nocodb 2>/dev/null || true

# Get admin email from user
echo "📧 Nhập email admin cho NocoDB:"
while true; do
    read -p "Email: " ADMIN_EMAIL
    
    # Validate email format
    if [[ "$ADMIN_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        break
    else
        echo "❌ Email không hợp lệ. Vui lòng nhập lại."
    fi
done

# Fix email in .env file
echo "Updating admin email in .env..."
if [[ -f ".env" ]]; then
    # Update with user's email
    sed -i "s/NOCODB_ADMIN_EMAIL=.*/NOCODB_ADMIN_EMAIL=$ADMIN_EMAIL/" .env
    echo "✅ Updated admin email to: $ADMIN_EMAIL"
    
    # Update password file
    ADMIN_PASSWORD=$(grep "NOCODB_ADMIN_PASSWORD=" .env | cut -d'=' -f2)
    echo "$ADMIN_PASSWORD" > .nocodb-admin-password
    chmod 600 .nocodb-admin-password
else
    echo "❌ .env file not found"
    exit 1
fi

# Restart NocoDB
echo "Restarting NocoDB with fixed email..."
docker compose up -d nocodb

# Wait for startup
echo "Waiting for NocoDB to start..."
sleep 10

# Check status
for i in {1..30}; do
    if curl -s "http://localhost:8080/api/v1/health" >/dev/null 2>&1; then
        echo "✅ NocoDB is now running!"
        echo "🌐 URL: http://$(curl -s ifconfig.me):8080"
        echo "👤 Email: admin@$DOMAIN"
        echo "🔑 Password: $ADMIN_PASSWORD"
        exit 0
    fi
    sleep 2
done

echo "❌ NocoDB still not responding after fix"
echo "Check logs: docker logs n8n-nocodb"