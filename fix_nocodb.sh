#!/bin/bash

# NocoDB Simple Fix - Direct approach without subpath complexity
set -euo pipefail

echo "🔧 NocoDB Simple Fix - Approach mới"

# 1. Stop và xóa container cũ
echo "1. Dọn dẹp container cũ..."
docker stop nocodb 2>/dev/null || true
docker rm nocodb 2>/dev/null || true

# 2. Get config từ hệ thống
domain="n8n-store.xyz"
port="8080"

# Get N8N database password
if [[ -f "/opt/n8n/.env" ]]; then
    n8n_db_password=$(grep "POSTGRES_PASSWORD=" /opt/n8n/.env | cut -d'=' -f2)
else
    echo "❌ Không tìm thấy N8N password"
    exit 1
fi

# 3. Tạo config đơn giản
echo "2. Tạo config đơn giản..."
mkdir -p /opt/nocodb

cat > /opt/nocodb/docker-compose.yml << 'EOF'
services:
  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      - NC_DB=pg://n8n-postgres:5432?u=n8n&p=${POSTGRES_PASSWORD}&d=n8n
      - NC_PUBLIC_URL=https://n8n-store.xyz/nocodb
      - NC_ADMIN_EMAIL=admin@n8n-store.xyz
      - NC_ADMIN_PASSWORD=FnnDn2107@#$
      - NC_DISABLE_TELE=true
      - PORT=8080
    volumes:
      - nocodb_data:/usr/app/data
    networks:
      - n8n_n8n-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 5

volumes:
  nocodb_data:

networks:
  n8n_n8n-network:
    external: true
EOF

# 4. Tạo .env
cat > /opt/nocodb/.env << EOF
POSTGRES_PASSWORD=$n8n_db_password
EOF

# 5. Sửa nginx config đơn giản
echo "3. Sửa nginx config..."
nginx_conf="/etc/nginx/sites-available/n8n-store.xyz.conf"

# Backup
cp "$nginx_conf" "${nginx_conf}.backup.$(date +%Y%m%d_%H%M%S)"

# Remove old nocodb config
sed -i '/# NocoDB subdirectory/,/^$/d' "$nginx_conf"

# Add simple config
sed -i '/location ~ \/\\./i\
    # NocoDB simple proxy\
    location /nocodb/ {\
        auth_basic "N8N Database Access";\
        auth_basic_user_file /etc/nginx/.htpasswd-nocodb;\
        \
        proxy_pass http://127.0.0.1:8080/;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\
        proxy_set_header X-Forwarded-Proto $scheme;\
        \
        proxy_http_version 1.1;\
        proxy_set_header Upgrade $http_upgrade;\
        proxy_set_header Connection "upgrade";\
        \
        client_max_body_size 50M;\
    }\
' "$nginx_conf"

# 6. Start services
echo "4. Khởi động services..."
cd /opt/nocodb
docker compose up -d

# 7. Reload nginx
nginx -t && systemctl reload nginx

# 8. Wait và test
echo "5. Đợi service khởi động..."
sleep 15

# Test local
if curl -s http://localhost:8080 | grep -q "Found"; then
    echo "✅ NocoDB local OK"
else
    echo "❌ NocoDB local fail"
fi

# Test through nginx
if curl -s -k https://n8n-store.xyz/nocodb | grep -q "Found\|html\|NocoDB"; then
    echo "✅ Nginx proxy OK"
else
    echo "❌ Nginx proxy fail"
fi

echo ""
echo "🎉 Setup hoàn tất!"
echo "URL: https://n8n-store.xyz/nocodb"
echo "Basic Auth: nocodb / 3nhkun2003"
echo "Admin: admin@n8n-store.xyz / FnnDn2107@#$"