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

provision_lets_encrypt_cert() {
    echo "=== Let's Encrypt Certificate Provisioning ==="
    echo "Domain: $DOMAIN"

    ACME_HOME="/root/.acme.sh"
    export ACME_HOME

    DNS_PROVIDER=""
    if [ -n "$CLOUDFLARE_EMAIL" ] && [ -n "$CLOUDFLARE_API_KEY" ]; then
        DNS_PROVIDER="cloudflare"
        echo "DNS Provider: Cloudflare"
        export CF_Token="$CLOUDFLARE_API_KEY"
    elif [ -n "$NAMECHEAP_USERNAME" ] && [ -n "$NAMECHEAP_API_KEY" ]; then
        DNS_PROVIDER="namecheap"
        echo "DNS Provider: Namecheap"
        export NAMECHEAP_USERNAME
        export NAMECHEAP_API_KEY
    else
        echo "ERROR: No DNS provider configured"
        echo "Set either CLOUDFLARE_EMAIL+CLOUDFLARE_API_KEY or NAMECHEAP_USERNAME+NAMECHEAP_API_KEY"
        return 1
    fi

    if [ -f "$LE_CERT" ] && [ -f "$LE_KEY" ]; then
        echo "Certificate already exists at $LE_CERT"
        CERT_INFO=$(openssl x509 -in "$LE_CERT" -noout -dates 2>/dev/null || echo "")
        if [ -n "$CERT_INFO" ]; then
            echo "Existing cert info:"
            echo "$CERT_INFO"
        fi
    fi

    ISSUE_ARGS="--issue -d $DOMAIN --keylength 4096 --force --email admin@$DOMAIN"
    case "$DNS_PROVIDER" in
        cloudflare)
            ISSUE_ARGS="$ISSUE_ARGS --dns dns_cf"
            ;;
        namecheap)
            ISSUE_ARGS="$ISSUE_ARGS --dns dns_namecheap"
            ;;
    esac

    if [ ! -f "$LE_CERT" ] || [ ! -f "$LE_KEY" ]; then
        echo "Issuing new Let's Encrypt certificate for $DOMAIN via DNS-01 challenge..."
        /root/.acme.sh/acme.sh $ISSUE_ARGS \
            || {
                echo "ERROR: acme.sh certificate issuance failed"
                return 1
            }
    else
        echo "Certificate exists, checking for renewal..."
        /root/.acme.sh/acme.sh --renew -d "$DOMAIN" --force \
            || echo "Renewal check completed"
    fi

    echo "Installing certificate to Prosody certificate directory..."
    /root/.acme.sh/acme.sh --install-cert \
        -d "$DOMAIN" \
        --key-file "$LE_KEY" \
        --fullchain-file "$LE_CERT" \
        --reloadcmd "prosodyctl reload" \
        || {
            echo "ERROR: Failed to install certificate"
            return 1
        }

    chown prosody:prosody "$LE_KEY" "$LE_CERT" 2>/dev/null || true
    echo "Certificate installed successfully"
    return 0
}

generate_self_signed_cert() {
    echo "=== Generating self-signed certificate (S2S federation will NOT work) ==="
    if [ ! -f "$LE_KEY" ]; then
        openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
            -keyout "$LE_KEY" \
            -out "$LE_CERT" \
            -subj "/CN=$DOMAIN/O=Gibber/C=US" 2>/dev/null
        chown prosody:prosody "$LE_KEY" "$LE_CERT" 2>/dev/null || true
        echo "Self-signed certificate generated"
    else
        echo "Self-signed certificate already exists"
    fi
}

if [ -n "$NAMECHEAP_USERNAME" ] && [ -n "$NAMECHEAP_API_KEY" ]; then
    echo "Namecheap API credentials detected, attempting Let's Encrypt..."
    if provision_lets_encrypt_cert; then
        echo "Let's Encrypt certificate provisioned successfully"
    else
        echo "Let's Encrypt provisioning failed, falling back to self-signed..."
        generate_self_signed_cert
    fi
else
    echo "=== WARNING: NAMECHEAP_USERNAME or NAMECHEAP_API_KEY not set ==="
    echo "=== S2S federation will NOT work without Let's Encrypt certificates ==="
    echo "To enable S2S federation, set these Railway environment variables:"
    echo "  NAMECHEAP_USERNAME=<your_namecheap_username>"
    echo "  NAMECHEAP_API_KEY=<your_namecheap_api_key>"
    echo ""
    echo "Note: You can also use Cloudflare DNS even if domain is registered at Namecheap."
    echo "      Set CLOUDFLARE_EMAIL and CLOUDFLARE_API_KEY instead."
    echo ""
    generate_self_signed_cert
fi

sed -i "s|/etc/prosody/certs/gibberapp.online.key|$LE_KEY|g" /etc/prosody/prosody.cfg.lua
sed -i "s|/etc/prosody/certs/gibberapp.online.crt|$LE_CERT|g" /etc/prosody/prosody.cfg.lua

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
command=/app/bin/server --host 0.0.0.0 --port ${PORT} --db-path /app/data/gibber_backend.db --config /etc/prosody/prosody.cfg.lua --mode "${REGISTRATION_MODE}" --use-docker "${USE_DOCKER}" --prosody-url "${PROSODY_URL}" --enable-sasl2 "${ENABLE_SASL2}" --jwt-secret "${JWT_SECRET}" --web-dir /app/web --turnstile-secret "${TURNSTONE_SECRET}" --turnstile-action "${TURNSTILE_ACTION}" --turnstile-hostnames "${TURNSTILE_HOSTNAMES}" --stripe-secret "${STRIPE_SECRET}" --stripe-webhook-secret "${STRIPE_WEBHOOK_SECRET}" --btcpay-url "${BTCPAY_URL}" --btcpay-api-key "${BTCPAY_API_KEY}" --btcpay-store-id "${BTCPAY_STORE_ID}"
environment=GIBBER_ADMIN_KEY="${ADMIN_KEY}",DOMAIN="${DOMAIN}",GIBBER_JWT_SECRET="${JWT_SECRET}",GIBBER_REGISTRATION_MODE="${REGISTRATION_MODE}",GIBBER_USE_DOCKER="${USE_DOCKER}",GIBBER_PROSODY_URL="${PROSODY_URL}",GIBBER_ENABLE_SASL2="${ENABLE_SASL2}",TURNSTILE_SECRET_KEY="${TURNSTONE_SECRET}",TURNSTILE_ACTION="${TURNSTILE_ACTION}",TURNSTILE_HOSTNAMES="${TURNSTILE_HOSTNAMES}",STRIPE_SECRET_KEY="${STRIPE_SECRET}",STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET}",BTCPAY_URL="${BTCPAY_URL}",BTCPAY_API_KEY="${BTCPAY_API_KEY}",BTCPAY_STORE_ID="${BTCPAY_STORE_ID}"
autostart=true
autorestart=true
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF

echo "Starting services..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
