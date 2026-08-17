#!/bin/bash
set -e

DOMAIN="${DOMAIN:-gibberapp.online}"
PORT="${PORT:-8080}"
ADMIN_KEY="${GIBBER_ADMIN_KEY:-gibber-admin-key-change-in-production}"
JWT_SECRET="${GIBBER_JWT_SECRET:-}"
REGISTRATION_MODE="${GIBBER_REGISTRATION_MODE:-xmpp}"
USE_DOCKER="${GIBBER_USE_DOCKER:-0}"
PROSODY_URL="${GIBBER_PROSODY_URL:-http://prosody:5280}"
ENABLE_SASL2="${GIBBER_ENABLE_SASL2:-1}"
TURNSTONE_SECRET="${TURNSTILE_SECRET_KEY:-}"
TURNSTILE_ACTION="${TURNSTILE_ACTION:-signup}"
TURNSTILE_HOSTNAMES="${TURNSTILE_HOSTNAMES:-gibberapp.online,localhost,127.0.0.1}"
STRIPE_SECRET="${STRIPE_SECRET_KEY:-}"
STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET:-}"
BTCPAY_URL="${BTCPAY_URL:-}"
BTCPAY_API_KEY="${BTCPAY_API_KEY:-}"
BTCPAY_STORE_ID="${BTCPAY_STORE_ID:-}"

echo "=== Gibber Entrypoint ==="
echo "Domain: $DOMAIN"
echo "Port: $PORT"
echo "Registration Mode: $REGISTRATION_MODE"
echo "JWT Secret Set: $([ -n "$JWT_SECRET" ] && echo 'yes' || echo 'no')"
echo "Use Docker: $USE_DOCKER"
echo "Prosody URL: $PROSODY_URL"
echo "Enable SASL2: $ENABLE_SASL2"

sed -i "s/gibberapp\.online/$DOMAIN/g" /etc/prosody/prosody.cfg.lua

if [ ! -f "/etc/prosody/certs/$DOMAIN.key" ]; then
    echo "Generating self-signed certificate for $DOMAIN..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -keyout "/etc/prosody/certs/$DOMAIN.key" \
        -out "/etc/prosody/certs/$DOMAIN.crt" \
        -subj "/CN=$DOMAIN/O=Gibber/C=US" 2>/dev/null
    chown prosody:prosody "/etc/prosody/certs/$DOMAIN.key" "/etc/prosody/certs/$DOMAIN.crt"
fi

sed -i "s|/etc/prosody/certs/gibberapp.online.key|/etc/prosody/certs/$DOMAIN.key|g" /etc/prosody/prosody.cfg.lua
sed -i "s|/etc/prosody/certs/gibberapp.online.crt|/etc/prosody/certs/$DOMAIN.crt|g" /etc/prosody/prosody.cfg.lua

mkdir -p /var/run/prosody /app/data /var/log/supervisor
chown -R prosody:prosody /var/run/prosody /var/lib/prosody

echo "Writing supervisord config..."
mkdir -p /etc/supervisor/conf.d

JWT_SECRET_ARG=""
if [ -n "$JWT_SECRET" ]; then
    JWT_SECRET_ARG="--jwt-secret $JWT_SECRET"
fi

cat > /etc/supervisor/conf.d/gibber.conf << EOF
[program:prosody]
command=/usr/bin/prosody -F
user=prosody
autostart=true
autorestart=true
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true

[program:gibber-backend]
command=/app/bin/server --host 0.0.0.0 --port ${PORT} --db-path /app/data/gibber_backend.db --config /etc/prosody/prosody.cfg.lua --mode "${REGISTRATION_MODE}" --use-docker "${USE_DOCKER}" --prosody-url "${PROSODY_URL}" --enable-sasl2 "${ENABLE_SASL2}" --jwt-secret "${JWT_SECRET}" --web-dir /app/web --turnstile-secret "${TURNSTILE_SECRET}" --turnstile-action "${TURNSTILE_ACTION}" --turnstile-hostnames "${TURNSTILE_HOSTNAMES}" --stripe-secret "${STRIPE_SECRET}" --stripe-webhook-secret "${STRIPE_WEBHOOK_SECRET}" --btcpay-url "${BTCPAY_URL}" --btcpay-api-key "${BTCPAY_API_KEY}" --btcpay-store-id "${BTCPAY_STORE_ID}"
environment=GIBBER_ADMIN_KEY="${ADMIN_KEY}",DOMAIN="${DOMAIN}",GIBBER_JWT_SECRET="${JWT_SECRET}",GIBBER_REGISTRATION_MODE="${REGISTRATION_MODE}",GIBBER_USE_DOCKER="${USE_DOCKER}",GIBBER_PROSODY_URL="${PROSODY_URL}",GIBBER_ENABLE_SASL2="${ENABLE_SASL2}",TURNSTILE_SECRET_KEY="${TURNSTILE_SECRET}",TURNSTILE_ACTION="${TURNSTILE_ACTION}",TURNSTILE_HOSTNAMES="${TURNSTILE_HOSTNAMES}",STRIPE_SECRET_KEY="${STRIPE_SECRET}",STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET}",BTCPAY_URL="${BTCPAY_URL}",BTCPAY_API_KEY="${BTCPAY_API_KEY}",BTCPAY_STORE_ID="${BTCPAY_STORE_ID}"
autostart=true
autorestart=true
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF

echo "Starting services..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
