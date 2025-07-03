#!/bin/bash

# Script dọn dẹp NocoDB cũ
echo "🧹 Dọn dẹp NocoDB và dữ liệu cũ..."

# Stop và remove containers
echo "Dừng containers..."
docker stop nocodb nocodb-postgres 2>/dev/null || true
docker rm -f nocodb nocodb-postgres 2>/dev/null || true

# Remove volumes
echo "Xóa volumes..."
docker volume rm nocodb_data nocodb_postgres_data nocodb_nocodb_data nocodb_nocodb_postgres_data 2>/dev/null || true

# Remove directories
echo "Xóa thư mục..."
sudo rm -rf /nocodb-cloud /opt/nocodb /opt/nocodb-db 2>/dev/null || true

# Remove database users
echo "Xóa database users..."
docker exec n8n-postgres psql -U n8n -d n8n -c "
DROP USER IF EXISTS nocodb_readonly;
DROP USER IF EXISTS nocodb_full;
" 2>/dev/null || true

# Clean nginx configs
echo "Dọn dẹp Nginx..."
for domain_conf in /etc/nginx/sites-available/*.conf; do
    if grep -q "location /nocodb" "$domain_conf" 2>/dev/null; then
        echo "Tìm thấy NocoDB config trong: $domain_conf"
        # Remove nocodb location block
        sudo sed -i '/# NocoDB subdirectory/,/^$/d' "$domain_conf" 2>/dev/null || true
    fi
done

# Remove htpasswd
sudo rm -f /etc/nginx/.htpasswd-nocodb 2>/dev/null || true

# Reload nginx
sudo systemctl reload nginx 2>/dev/null || true

echo "✅ Dọn dẹp hoàn tất!"
