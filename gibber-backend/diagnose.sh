#!/bin/bash
# Diagnostic script to verify XMPP registration and auth
# Run from the gibber-backend directory after rebuilding containers
# Registration mode: internal (shared volume, no Docker socket)

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

echo "4. Checking Prosody data directory..."
docker exec gibber_xmpp ls -la /var/lib/prosody/gibberapp.online/accounts/ 2>&1 || echo "No accounts directory yet"
echo ""

echo "5. Checking backend can see Prosody data directory..."
docker exec gibber_backend ls -la /var/lib/prosody/gibberapp.online/ 2>&1 || echo "Backend cannot see Prosody data directory"
echo ""

echo "6. Testing backend registration API..."
curl -s -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"apitest","password":"apitest12345"}' | python3 -m json.tool 2>/dev/null || \
curl -s -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"apitest","password":"apitest12345"}'
echo ""

echo "7. Verifying API-created user file exists..."
docker exec gibber_backend ls -la /var/lib/prosody/gibberapp.online/accounts/apitest.dat 2>&1
echo ""

echo "8. Verifying user file is readable by Prosody..."
docker exec gibber_xmpp cat /var/lib/prosody/gibberapp.online/accounts/apitest.dat 2>&1
echo ""

echo "9. Verifying user exists via prosodyctl..."
docker exec gibber_xmpp prosodyctl user exists apitest gibberapp.online
echo ""

echo "10. Cleaning up test user..."
curl -s -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"apitest","password":"apitest12345"}' > /dev/null 2>&1
# Delete the user file directly since we're in internal mode
docker exec gibber_backend rm -f /var/lib/prosody/gibberapp.online/accounts/apitest.dat
echo "Cleaned up"
echo ""

echo "11. Checking backend logs (last 30 lines)..."
docker logs --tail 30 gibber_backend
echo ""

echo "12. Checking backend config endpoint..."
curl -s http://localhost:8080/config | python3 -m json.tool 2>/dev/null || \
curl -s http://localhost:8080/config
echo ""

echo "=== Diagnostics complete ==="