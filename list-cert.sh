#!/bin/bash

# Certificate History Checker
# Kiểm tra lịch sử certificates đã lấy

set -euo pipefail

DOMAIN="${1:-n8n-store.xyz}"

echo "🔍 Kiểm tra certificates cho domain: $DOMAIN"
echo "================================================="

# 1. Check local certificates
echo ""
echo "📁 1. Certificates local:"
if [[ -d "/etc/letsencrypt/live" ]]; then
    ls -la /etc/letsencrypt/live/ | grep "$DOMAIN" || echo "Không có certificates local"
    
    if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
        echo ""
        echo "📄 Certificate details:"
        openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/cert.pem" -text -noout | grep -E "Not Before|Not After|Serial Number" || true
    fi
else
    echo "Thư mục letsencrypt chưa tồn tại"
fi

# 2. Check certbot logs
echo ""
echo "📝 2. Certbot logs (10 dòng cuối):"
if [[ -f "/var/log/letsencrypt/letsencrypt.log" ]]; then
    tail -10 /var/log/letsencrypt/letsencrypt.log | grep -E "$DOMAIN|rate|limit|issued" || echo "Không có logs liên quan"
else
    echo "Không có certbot logs"
fi

# 3. Check certificate transparency logs
echo ""
echo "🌐 3. Certificate transparency (online check):"
if command -v curl >/dev/null 2>&1; then
    echo "Đang kiểm tra crt.sh..."
    
    # Query crt.sh API
    CERT_DATA=$(curl -s "https://crt.sh/?q=$DOMAIN&output=json" || echo "[]")
    
    if [[ "$CERT_DATA" != "[]" && -n "$CERT_DATA" ]]; then
        echo "$CERT_DATA" | jq -r '.[] | select(.issuer_name | contains("Let")) | "\(.logged_at[:10]) - \(.issuer_name)"' 2>/dev/null | head -10 || {
            # Fallback nếu không có jq
            echo "$CERT_DATA" | grep -o '"logged_at":"[^"]*' | cut -d'"' -f4 | head -5
        }
    else
        echo "Không tìm thấy certificates public"
    fi
else
    echo "Cần curl để check online"
fi

# 4. Check rate limit status
echo ""
echo "⚠️  4. Rate limit analysis:"

# Count recent certificates from logs
if [[ -f "/var/log/letsencrypt/letsencrypt.log" ]]; then
    RECENT_CERTS=$(grep -c "Congratulations" /var/log/letsencrypt/letsencrypt.log 2>/dev/null || echo "0")
    echo "Certificates issued (theo logs): $RECENT_CERTS"
    
    # Check for rate limit messages
    RATE_LIMIT_MSG=$(grep -i "too many certificates" /var/log/letsencrypt/letsencrypt.log | tail -1 || echo "")
    if [[ -n "$RATE_LIMIT_MSG" ]]; then
        echo "🚨 Rate limit message:"
        echo "$RATE_LIMIT_MSG"
    fi
fi

# 5. Recommendations
echo ""
echo "💡 5. Khuyến nghị:"
echo "- Rate limit: 5 certs/tuần cho exact domain"
echo "- Subdomain riêng biệt không bị limit: app.$DOMAIN"
echo "- Staging environment unlimited: certbot --staging"
echo "- Self-signed tạm thời: openssl req -x509 ..."

echo ""
echo "🔧 Quick solutions:"
echo "1) Chờ 7 ngày reset rate limit"
echo "2) Dùng subdomain: certbot -d app.$DOMAIN"
echo "3) Test staging: certbot --staging -d $DOMAIN"