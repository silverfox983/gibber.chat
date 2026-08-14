#!/bin/bash
# Diagnostic script to verify XMPP registration and auth
# Run from the gibber-backend directory after rebuilding containers

set -e

echo "=== Gibber XMPP Registration Diagnostics ==="
echo ""

echo "1. Checking Docker containers..."
docker compose ps
echo ""

echo "2. Checking Prosody status..."
docker exec gibber_xmpp prosodyctl status
echo ""

echo "3. Listing existing users..."
docker exec gibber_xmpp prosodyctl user list gibberapp.online 2>&1 || echo "No users found or command failed"
echo ""

echo "4. Testing user creation..."
docker exec gibber_xmpp prosodyctl register diagtest gibberapp.online diagtest12345
echo ""

echo "5. Verifying user was created..."
docker exec gibber_xmpp prosodyctl user exists diagtest gibberapp.online
echo ""

echo "6. Testing user deletion..."
docker exec gibber_xmpp prosodyctl user delete diagtest gibberapp.online
echo ""

echo "7. Checking backend logs (last 20 lines)..."
docker logs --tail 20 gibber_backend
echo ""

echo "8. Testing backend registration API..."
curl -s -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"apitest","password":"apitest12345"}' | python3 -m json.tool 2>/dev/null || \
curl -s -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"apitest","password":"apitest12345"}'
echo ""

echo "9. Verifying API-created user exists in Prosody..."
docker exec gibber_xmpp prosodyctl user exists apitest gibberapp.online
echo ""

echo "10. Cleaning up API test user..."
docker exec gibber_xmpp prosodyctl user delete apitest gibberapp.online
echo ""

echo "11. Checking backend config endpoint..."
curl -s http://localhost:8080/config | python3 -m json.tool 2>/dev/null || \
curl -s http://localhost:8080/config
echo ""

echo "=== Diagnostics complete ==="