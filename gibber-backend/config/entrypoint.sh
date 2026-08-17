#!/bin/bash
set -e

# Read Railway/docker-compose environment variables
RAILWAY_GIBBER_JWT_SECRET="${GIBBER_JWT_SECRET:-}"
RAILWAY_GIBBER_REGISTRATION_MODE="${GIBBER_REGISTRATION_MODE:-}"
RAILWAY_GIBBER_USE_DOCKER="${GIBBER_USE_DOCKER:-}"
RAILWAY_GIBBER_PROSODY_URL="${GIBBER_PROSODY_URL:-}"

# Default values (used when Railway sets empty or wrong values)
DEFAULT_JWT_SECRET="change-me-in-production-use-a-strong-random-string"
DEFAULT_REGISTRATION_MODE="xmpp"
DEFAULT_USE_DOCKER="1"
DEFAULT_PROSODY_URL="http://localhost:5280"

# Use Railway value if non-empty, otherwise use default
JWT_SECRET="${RAILWAY_GIBBER_JWT_SECRET:-$DEFAULT_JWT_SECRET}"
REGISTRATION_MODE="${RAILWAY_GIBBER_REGISTRATION_MODE:-$DEFAULT_REGISTRATION_MODE}"
USE_DOCKER="${RAILWAY_GIBBER_USE_DOCKER:-$DEFAULT_USE_DOCKER}"
PROSODY_URL="${RAILWAY_GIBBER_PROSODY_URL:-$DEFAULT_PROSODY_URL}"

# Force correct values if Railway set wrong ones
if [ "$REGISTRATION_MODE" = "internal" ] || [ -z "$REGISTRATION_MODE" ]; then
    echo "WARNING: Railway override detected (REGISTRATION_MODE=$REGISTRATION_MODE). Forcing to xmpp."
    REGISTRATION_MODE="xmpp"
fi

if [ "$USE_DOCKER" = "0" ] || [ -z "$USE_DOCKER" ]; then
    if [ -f /app/bin/server ]; then
        echo "WARNING: USE_DOCKER=$USE_DOCKER but running in container. Forcing to 1."
        USE_DOCKER="1"
    fi
fi

# Read remaining vars
DOMAIN="${DOMAIN:-gibberapp.online}"
PORT="${PORT:-8080}"
ADMIN_KEY="${GIBBER_ADMIN_KEY:-gibber-admin-key-change-in-production}"
ENABLE_SASL2="${GIBBER_ENABLE_SASL2:-1}"
TURNSTONE_SECRET="${TURNSTILE_SECRET_KEY:-}"
TURNSTILE_ACTION="${TURNSTILE_ACTION:-signup}"
TURNSTILE_HOSTNAMES="${TURNSTILE_HOSTNAMES:-gibberapp.online,localhost,127.0.0.1}"
STRIPE_SECRET="${STRIPE_SECRET_KEY:-}"
STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET:-}"
BTCPAY_URL="${BTCPAY_URL:-}"
BTCPAY_API_KEY="${BTCPAY_API_KEY:-}"
BTCPAY_STORE_ID="${BTCPAY_STORE_ID:-}"

if [ -z "$JWT_SECRET" ]; then
    echo "WARNING: JWT_SECRET not set. Auth will be disabled."
fi

echo "=== Gibber Entrypoint ==="
echo "Domain: $DOMAIN"
echo "Port: $PORT"
echo "Registration Mode: $REGISTRATION_MODE"
echo "JWT Secret Set: $([ -n "$JWT_SECRET" ] && echo 'yes' || echo 'no')"
echo "Use Docker: $USE_DOCKER"
echo "Prosody URL: $PROSODY_URL"
echo "Enable SASL2: $ENABLE_SASL2"

sed -i "s/gibberapp\.online/$DOMAIN/g" /etc/prosody/prosody.cfg.lua

CERT_DIR="/etc/prosody/certs"
LE_CERT="$CERT_DIR/$DOMAIN.crt"
LE_KEY="$CERT_DIR/$DOMAIN.key"

# Always generate a self-signed cert first so Prosody can start immediately.
# If Let's Encrypt succeeds later, we overwrite this and reload Prosody.
if [ ! -f "$LE_KEY" ] || [ ! -f "$LE_CERT" ]; then
    echo "Generating temporary self-signed certificate (will be replaced by LE if DNS API is configured)..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -keyout "$LE_KEY" \
        -out "$LE_CERT" \
        -subj "/CN=$DOMAIN/O=Gibber/C=US" 2>/dev/null
    chown prosody:prosody "$LE_KEY" "$LE_CERT" 2>/dev/null || true
fi

sed -i "s|/etc/prosody/certs/gibberapp.online.key|$LE_KEY|g" /etc/prosody/prosody.cfg.lua
sed -i "s|/etc/prosody/certs/gibberapp.online.crt|$LE_CERT|g" /etc/prosody/prosody.cfg.lua

mkdir -p /var/run/prosody /app/data /var/log/supervisor /etc/supervisor/conf.d
chown -R prosody:prosody /var/run/prosody /var/lib/prosody

echo "Writing supervisord config..."
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
command=/app/bin/server --host 0.0.0.0 --port ${PORT} --db-path /app/data/gibber_backend.db --config /etc/prosody/prosody.cfg.lua --mode "${REGISTRATION_MODE}" --use-docker "${USE_DOCKER}" --prosody-url "${PROSODY_URL}" --enable-sasl2 "${ENABLE_SASL2}" --jwt-secret "${JWT_SECRET}" --web-dir /app/web --turnstile-secret "${TURNSTONE_SECRET}" --turnstile-action "${TURNSTILE_ACTION}" --turnstile-hostnames "${TURNSTILE_HOSTNAMES}" --stripe-secret "${STRIPE_SECRET}" --stripe-webhook-secret "${STRIPE_WEBHOOK_SECRET}" --btcpay-url "${BTCPAY_URL}" --btcpay-api-key "${BTCPAY_API_KEY}" --btcpay-store-id "${BTCPAY_STORE_ID}"
environment=GIBBER_ADMIN_KEY="${ADMIN_KEY}",DOMAIN="${DOMAIN}",GIBBER_JWT_SECRET="${JWT_SECRET}",GIBBER_REGISTRATION_MODE="${REGISTRATION_MODE}",GIBBER_USE_DOCKER="${USE_DOCKER}",GIBBER_PROSODY_URL="${PROSODY_URL}",GIBBER_ENABLE_SASL2="${ENABLE_SASL2}",TURNSTILE_SECRET_KEY="${TURNSTONE_SECRET}",TURNSTILE_ACTION="${TURNSTILE_ACTION}",TURNSTILE_HOSTNAMES="${TURNSTILE_HOSTNAMES}",STRIPE_SECRET_KEY="${STRIPE_SECRET}",STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET}",BTCPAY_URL="${BTCPAY_URL}",BTCPAY_API_KEY="${BTCPAY_API_KEY}",BTCPAY_STORE_ID="${BTCPAY_STORE_ID}"
autostart=true
autorestart=true
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF

echo "Starting services with temporary certificate..."
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf &
SUPERVISOR_PID=$!
sleep 3

# Now attempt Let's Encrypt if DNS API credentials are configured
HAVE_DNS_CREDENTIALS=false
if ([ -n "$CLOUDFLARE_EMAIL" ] && [ -n "$CLOUDFLARE_GLOBAL_API_KEY" ]) || ([ -n "$CLOUDFLARE_EMAIL" ] && [ -n "$CLOUDFLARE_API_KEY" ]) || ([ -n "$NAMECHEAP_USERNAME" ] && [ -n "$NAMECHEAP_API_KEY" ]); then
    HAVE_DNS_CREDENTIALS=true
fi

if $HAVE_DNS_CREDENTIALS; then
    echo "=== Let's Encrypt Certificate Provisioning ==="
    echo "Domain: $DOMAIN"

    ACME_HOME="/root/.acme.sh"
    export ACME_HOME

    DNS_PROVIDER=""
    if [ -n "$CLOUDFLARE_EMAIL" ] && [ -n "$CLOUDFLARE_GLOBAL_API_KEY" ]; then
        DNS_PROVIDER="cloudflare"
        echo "DNS Provider: Cloudflare (Global API Key)"
        export CF_Key="$CLOUDFLARE_GLOBAL_API_KEY"
        export CF_Email="$CLOUDFLARE_EMAIL"
    elif [ -n "$CLOUDFLARE_EMAIL" ] && [ -n "$CLOUDFLARE_API_KEY" ]; then
        DNS_PROVIDER="cloudflare"
        echo "DNS Provider: Cloudflare (API Token)"
        export CF_Token="$CLOUDFLARE_API_KEY"
        export CF_Email="$CLOUDFLARE_EMAIL"
        if [ -n "$CLOUDFLARE_ACCOUNT_ID" ]; then
            export CF_Account_ID="$CLOUDFLARE_ACCOUNT_ID"
            echo "Cloudflare Account ID: $CLOUDFLARE_ACCOUNT_ID"
        fi
    elif [ -n "$NAMECHEAP_USERNAME" ] && [ -n "$NAMECHEAP_API_KEY" ]; then
        DNS_PROVIDER="namecheap"
        echo "DNS Provider: Namecheap"
        export NAMECHEAP_USERNAME
        export NAMECHEAP_API_KEY
    fi

    ISSUE_ARGS="--issue -d $DOMAIN --keylength 4096 --force --email admin@$DOMAIN --server letsencrypt --debug"
    case "$DNS_PROVIDER" in
        cloudflare)
            ISSUE_ARGS="$ISSUE_ARGS --dns dns_cf"
            ;;
        namecheap)
            ISSUE_ARGS="$ISSUE_ARGS --dns dns_namecheap"
            ;;
    esac

    echo "Issuing Let's Encrypt certificate for $DOMAIN via DNS-01 challenge..."
    if /root/.acme.sh/acme.sh $ISSUE_ARGS; then
        echo "Certificate issued! Installing to Prosody certificate directory..."
        if /root/.acme.sh/acme.sh --install-cert \
            -d "$DOMAIN" \
            --key-file "$LE_KEY" \
            --fullchain-file "$LE_CERT" \
            --reloadcmd "prosodyctl reload"; then
            chown prosody:prosody "$LE_KEY" "$LE_CERT" 2>/dev/null || true
            echo "Let's Encrypt certificate installed successfully!"

            echo "Reloading Prosody to use Let's Encrypt certificate..."
            prosodyctl reload 2>/dev/null || true
            echo "Prosody reloaded with Let's Encrypt certificate!"
        else
            echo "WARNING: Failed to install Let's Encrypt certificate, keeping self-signed"
        fi
    else
        echo "WARNING: Let's Encrypt issuance failed, keeping self-signed certificate"
        echo "S2S federation will NOT work with a self-signed certificate"
    fi
else
    echo "=== WARNING: No DNS API credentials configured ==="
    echo "=== S2S federation will NOT work without Let's Encrypt certificates ==="
    echo "To enable S2S federation, set one of these Railway environment variable groups:"
    echo "  Cloudflare Global API Key (recommended): CLOUDFLARE_EMAIL + CLOUDFLARE_GLOBAL_API_KEY"
    echo "  Cloudflare API Token: CLOUDFLARE_EMAIL + CLOUDFLARE_API_KEY + CLOUDFLARE_ACCOUNT_ID"
    echo "  Namecheap: NAMECHEAP_USERNAME + NAMECHEAP_API_KEY"
    echo ""
    echo "Using self-signed certificate (S2S federation will NOT work)"
fi

echo "=== Startup complete ==="
wait $SUPERVISOR_PID