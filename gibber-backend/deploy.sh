#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Gibber Web Build & Deploy ==="
echo "Project root: $PROJECT_ROOT"

# Step 1: Build Flutter web
echo ""
echo "[1/3] Building Flutter web..."
cd "$PROJECT_ROOT"
flutter build web --release --web-renderer canvaskit

# Step 2: Copy build output to backend's web directory
echo ""
echo "[2/3] Copying build to backend web directory..."
WEB_DIR="$PROJECT_ROOT/gibber-backend/web"
mkdir -p "$WEB_DIR"
rm -rf "$WEB_DIR"/*
cp -r "$PROJECT_ROOT/build/web/"* "$WEB_DIR/"

echo "Web files copied to $WEB_DIR"

# Step 3: Rebuild and deploy Docker containers
echo ""
echo "[3/3] Rebuilding Docker containers..."
cd "$PROJECT_ROOT/gibber-backend"

echo "  Stopping existing containers..."
docker compose down 2>/dev/null || true

echo "  Building backend image..."
docker compose build --no-cache

echo "  Starting containers..."
docker compose up -d

echo ""
echo "=== Deployment complete ==="
echo "  Backend API: http://localhost:8080"
echo "  XMPP WebSocket: ws://localhost:5280/xmpp-websocket"
echo "  Web app: http://localhost:8080 (served by backend)"
echo ""
echo "  For production with Caddy (TLS):"
echo "  docker compose --profile caddy up -d"
echo ""
echo "  Health check: curl http://localhost:8080/health"