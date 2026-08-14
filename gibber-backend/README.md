# Gibber Backend

Dart shelf server powering the Gibber platform: XMPP user registration, miner coordination, entitlement management, and protocol gateway authorization.

## Quick Start

### With Docker Compose (recommended)

```bash
cd gibber-backend
docker compose up -d
```

This starts:
- **Prosody XMPP** on ports 5222 (client), 5280/5281 (BOSH/WebSocket)
- **Gibber Backend** on port 8080

### Without Docker

```bash
cd gibber-backend
dart pub get
dart run bin/server.dart
```

Requires Prosody installed locally with `prosodyctl` in PATH.

## API Endpoints

### XMPP Registration

```
POST /register
  Body: { "username": "user", "password": "secret123", "host": "gibber.chat" }
  Response: { "jid": "user@gibber.chat", "message": "Registration successful" }

POST /register/check
  Body: { "username": "user", "host": "gibber.chat" }
  Response: { "available": true }
```

### Entitlements

```
GET /entitlements/<jid>
  Response: { "tier": "pro", "additionalProtocols": ["Slack"], "miningCredits": 152.3, ... }

POST /redeem
  Body: { "code": "ABCD-EFGH-JKLM-NPQR", "jid": "user@gibber.chat" }
  Response: { "tier": "pro", "additionalProtocols": ["Slack"], "expiresAt": "2027-08-13T..." }
```

### Gateway Authorization

```
POST /gateways/authorize
  Body: { "jid": "user@gibber.chat", "protocol": "Slack" }
  Response: { "authorized": true, "jid": "...", "protocol": "Slack" }

GET /gateways/check/<jid>/<protocol>
  Response: { "authorized": true, "jid": "...", "protocol": "Slack" }
```

### Miner

```
POST /miner/register
  Body: { "jid": "user@gibber.chat", "cpuCap": 0.3 }
  Response: { "sessionToken": "uuid", "jid": "...", "cpuCap": 0.3 }

POST /miner/credits
  Header: Authorization: Bearer <sessionToken>
  Body: { "hashes": 150.0 }
  Response: { "credits": 0.00150 }

POST /miner/heartbeat
  Header: Authorization: Bearer <sessionToken>
  Response: { "status": "ok" }

GET /miner/stats/<jid>
  Response: { "totalCredits": 0.00150, "tier": "free", "activeSessions": 1 }
```

### Admin

```
POST /codes
  Body: { "tier": "pro", "protocols": ["Slack", "Discord"], "durationDays": 30 }
  Response: { "code": "ABCD-EFGH-JKLM-NPQR", ... }

GET /codes
  Response: [ { "code": "...", "tier": "pro", ... }, ... ]

GET /health
  Response: { "status": "healthy", "domain": "gibber.chat" }
```

## Tier System

| Tier   | Credits Required | Protocols                                    | Transcription min/mo | AI queries/mo |
|--------|-----------------|----------------------------------------------|---------------------|---------------|
| Free   | 0               | XMPP                                         | 30                  | 10            |
| Pro    | 100             | XMPP, Slack, Discord, IRC                    | 300                 | 100           |
| Ultimate | 1000          | XMPP, Slack, Discord, IRC, Teams, Matrix, Telegram, SMS | Unlimited    | Unlimited     |

## Configuration

Environment variables:
- `GIBBER_DB_PATH` — SQLite database path (default: `gibber_backend.db`)
- `GIBBER_PROSODY_CONFIG` — Path to Prosody config (default: `config/prosody.cfg.lua`)
- `GIBBER_PROSODYCTL_PATH` — Path to `prosodyctl` binary (default: `prosodyctl`)
- `GIBBER_HOST` — Server bind address (default: `0.0.0.0`)
- `GIBBER_PORT` — Server port (default: `8080`)