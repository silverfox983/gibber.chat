<div align="center">

<img src="assets/logo.png" width="72" alt="Gibber logo" />

# 🌌 Gibber

**Free & local chat for everyone. Everything unlocked, no pricing, no data harvesting.**

[![Flutter](https://img.shields.io/badge/Flutter-3.47-blue.svg?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.11-blue.svg?logo=dart)](https://dart.dev)
[![Platforms](https://img.shields.io/badge/Platform-Web%20%7C%20Android%20%7C%20Linux%20%7C%20Windows-lightgrey.svg)](#platforms)
[![Self-hosted](https://img.shields.io/badge/Self--hosted-docker%20compose-2496ED.svg?logo=docker&logoColor=white)](#run-the-whole-stack)

</div>

**Gibber** is a modern communication client built with **Flutter / Dart**: XMPP messaging, encrypted OMEMO chats, WebRTC voice & video (1:1, group, SIP/PSTN), Spaces (PubSub communities/microblogging), and bridges into **IRC, Telegram, Discord, Matrix and WhatsApp** — all in one polished, glassmorphic UI.

Gibber is *free and open source*. There is no paid tier, no ads and no tracking. Your data lives on your device (SQLite) and on the server you point it at — bring your own XMPP server, or run the entire stack locally with one command.

---

## ✨ Highlights

- **XMPP messenger** — XEP-0384 OMEMO encryption, MAM history, carbons, XEP-0308 edits, message moderation, hats, spoilers, locations, reactions, voice notes, file sharing (XEP-0363 / SFS), stickers
- **Calls** — Jingle (XEP-0166/0353) with trickle ICE, PSTN via SIP gateways, group calls over Janus SFU or full mesh, screen sharing, DTMF, transfer, hold, call recording
- **Spaces** — communities over XEP-0060 PubSub: feeds, posts, threads, likes, comments, rooms, member management, stories
- **Gateways** — one-click bridges into IRC (biboumi), Telegram / Discord / Matrix / WhatsApp (Slidge). Registration is per-protocol: WhatsApp shows the pairing QR inline and waits for the scan, Telegram walks through code entry, Discord offers a channel picker for your guilds. Bridged contacts appear in your list automatically (roster pushes + gateway auto-approval), and any gateway that only supports chat commands gets its own conversation
- **Guests** — web visitors are signed in automatically with a persistent guest account; "Claim account" (profile banner or the landing CTA) turns the guest into a real username and moves chats, contacts and rooms over
- **Trending rooms** — the landing page lists the most active public IRC rooms (from [netsplit.de](https://netsplit.de/channels/popular.php)) and deep-links into a join flow
- **Free & local** — unlimited transcription/AI, unlimited group calls, full history, every protocol; self-host everything with docker compose

## 🚀 Run the whole stack

The repo ships a complete self-hostable stack:

```
web (Flutter) → caddy (TLS, self-signed) → gibber-backend (REST + WS proxy)
                                          → prosody (XMPP) → biboumi IRC / slidge ×4
                                          → janus (SFU) · coturn (TURN)
```

```bash
cp .env.example .env      # optional: edit secrets for a long-lived install
docker compose up -d      # core web app
# add all gateways:
docker compose --profile slidge up -d
# or just IRC (trending-room joins):
docker compose --profile irc up -d
```

Then open:

- **`https://localhost`** — TLS with a Caddy-managed self-signed certificate (browsers prompt once to trust it)
- **`http://localhost:8080`** — plain HTTP via the backend (useful before DNS is set up)

Create an account right in the app (in-band XMPP registration through your local Prosody) and join rooms — including the trending IRC rooms on the landing page.

> Cloudflare / Let's Encrypt plumbing was removed by design. This is a local-first stack; certificates are self-signed. When you later point a real domain at it, Caddy can be switched back to ACME.

### Gateway profiles

| Profile | Gateway | Notes |
|---|---|---|
| `irc` | biboumi | Bridges one IRC network (`IRC_SERVER_HOSTNAME`, default `irc.libera.chat`) — used by the landing-page join flow |
| `telegram` | slidgram | Users register with their own Telegram account |
| `discord` | slidcord | Users register with their own Discord account |
| `matrix` | matridge | Users register with their own Matrix account |
| `whatsapp` | slidge-whatsapp | Linked-device pairing |
| `slidge` | all of the above | Bring up everything |

## 💻 Client development

The client is a standard Flutter app. Web is the primary platform; desktop and Android work too.

```bash
flutter pub get

flutter run -d chrome          # web (recommended for local testing)
flutter run -d windows         # windows
flutter run -d linux           # linux (see native build notes below)
flutter run -d android         # android

flutter test                   # full suite
flutter analyze                # lint
```

Linux native builds need GTK/GStreamer toolchain (`ninja-build`, `libgtk-3-dev`, `libgstreamer1.0-dev`, `clang`, `cmake`); if you hit C++ include errors, export `CPLUS_INCLUDE_PATH=/usr/include/c++/13:/usr/include/x86_64-linux-gnu/c++/13` first.

Without a server, any XMPP account works — point the login at any XMPP domain, or host the stack above and the client auto-configures from `GET /config`.

## 🧪 Test gate

`flutter analyze` (0 errors enforced) and the core suite run in CI:

```bash
flutter test test/iq_request_manager_test.dart \
             test/chat_models_test.dart \
             test/chat_provider_db_test.dart \
             test/join_intent_test.dart \
             test/popular_rooms_test.dart \
             test/pstn_gateway_test.dart \
             test/omemo_test.dart test/call_test.dart test/simple_test.dart
```

The XMPP stack itself (`packages/xmpp_stone`) carries its own tests: `dart test` inside that folder.

## 🏗 Architecture

```
lib/
├── screens/            # landing (trending rooms), chat, spaces, calls, settings
├── providers/          # ChatProvider, CallProvider — UI state machines
├── services/           # XMPP stack (auth, rooms, OMEMO, Jingle, IqRequestManager…)
│                       # gateways, notifications, database (SQLite), media
├── models/             # chat/spaces models, join intents
├── widgets/            # chat_view, dialogs, nav rail, shared components
└── router/             # go_router configuration (deep links for room joins)
gibber-backend/         # Dart shelf server: registration, JWT, entitlements,
                        # gateway mgmt, XMPP websocket proxy, static web host
docker/                 # web.Dockerfile, Caddyfile.compose, biboumi config
packages/
├── xmpp_stone/         # vendored, patched fork (SASL2, stream-mgmt fix, SMACK)
└── sip_ua/             # vendored, patch (strict JS-interop for web builds)
```

Key services (post-refactor): `AuthService` owns connections; per-feature services (`XmppRoomService`, `XmppMessageService`, `OmemoService`, `JingleSignalingService`, `SpacesService`…) communicate through shared primitives (`IqRequestManager`/`CompleterMap`, `XmppSessionLookup`, single stanza dispatch). `REFACTOR_PLAN.md` documents the architecture work and its gates.

## 🛠 Notes & gotchas

- **Self-signed certs are intentional.** Caddy uses `tls internal`; Prosody ships a self-signed cert. Federation *from* other servers won't validate — fine for local/private deployments.
- **WSL2/Docker Desktop**: if a pull or build wedges (containerd "read-only file system"), a full Docker Desktop restart plus `docker builder prune -af` clears it.
- **Windows checkouts**: entrypoint scripts are CRLF-normalized at build time; `.gitattributes` keeps shell/Lua files LF.
- **Loopback port 443**: WSL's localhost-forwarding relay can shadow published ports on `127.0.0.1`. Browsers are unaffected (Docker Desktop handles them); CLI tools can use `--resolve <domain>:443:127.0.0.2`.
- **Alpha software**: expect rough edges — the IRC bridge serves one network per biboumi instance; gateway availability is reported by the backend `/gateways` endpoint which the join flow reflects honestly (bridge missing / join failed / success).

## 📜 License

MIT. Chat is a right, not a product.