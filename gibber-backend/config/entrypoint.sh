#!/bin/bash
set -e

DOMAIN="${DOMAIN:-gibberapp.online}"
PORT="${PORT:-8080}"
ADMIN_KEY="${GIBBER_ADMIN_KEY:-gibber-admin-key-change-in-production}"
TURNSTILE_SECRET="${TURNSTILE_SECRET_KEY:-}"

echo "=== Gibber Railway Entrypoint ==="
echo "Domain: $DOMAIN"
echo "Port: $PORT"

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
command=/app/bin/server --host 0.0.0.0 --port ${PORT} --db-path /app/data/gibber_backend.db --config /etc/prosody/prosody.cfg.lua --mode internal --web-dir /app/web --turnstile-secret "${TURNSTILE_SECRET}"
environment=GIBBER_ADMIN_KEY="${ADMIN_KEY}",DOMAIN="${DOMAIN}",TURNSTILE_SECRET_KEY="${TURNSTILE_SECRET}"
autostart=true
autorestart=true
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF

echo "Starting services..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf