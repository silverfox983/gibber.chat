# Gibber Refactor Plan

Tracking document for the XMPP-client refactor. Status updates live here; each phase ships as
behavior-preserving commits gated by the checks below.

## Baseline (2026-11-01, tag `pre-refactor`)

| Gate | Command | Result |
|---|---|---|
| Core tests | `flutter test test/simple_test.dart test/omemo_test.dart test/call_test.dart` | **All pass (+4)** |
| Full suite | `flutter test` | +8 / −13 (13 pre-existing widget-test failures: RenderFlex overflow `login_screen.dart:220`, etc.) |
| Analyzer | `flutter analyze` | `lib/` 0 errors, 93 warnings, 260 infos |

Code shape at baseline: 186 Dart files in `lib/`, ~69k lines. Largest: `main_chat_screen` (4.3k),
`spaces_screen` (4.3k), `spaces_service` (3.0k), `auth_service` (2.8k), `call_provider` (2.6k).

## Phase 0 — Safety rails  ✅

- [x] Commit outstanding WIP (`793d93e`).
- [x] Tag baseline `pre-refactor`.
- [x] Make VM test compilation work: split `push_notification_service.dart` into web/stub
      conditional imports (`34545cd`). Core test gate now green.
- [x] Record analyzer/test baselines (above).

## Phase 1 — Deletion pass  (no behavior change, −~3k lines)

- [ ] Remove dead chat block in `main_chat_screen.dart` (never-called `_buildChatContent` and
      friends, ~lines 971–3826, incl. two unreached forward dialogs). Live code uses
      `widgets/chat/chat_view.dart`.
- [ ] Remove dead `ChatMessage.senderColor` getter; unused `SfsUrlSource/SfsFile` review (keep if
      wired to stanza handler — they are).
- [ ] Drop vendored `packages/sip_ua` (unmodified upstream 1.1.0) → revert to pub dependency.
- [ ] Gate: core tests + analyzer error count stay at 0.

## Phase 2 — Shared XMPP infrastructure

- [ ] `IqRequestManager`: one `_pendingIqs` map + `sendIqAndWait()` per connection (replaces the
      copy-paste in 10+ services: auth, transport, registration, pubsub_interaction, pep,
      server_info, room, room_enhancements ×2, spaces, sticker).
- [ ] `XmppSession` value object (connection + JID + accountId) replacing `connectionMap` reach-ins
      and the `setAccountIdMapper` closure in `SpacesService`.
- [ ] Single stanza dispatch bus `XmppSession.multiplexedStanzas` — stop `SpacesService` listening
      to `Connection.inStanzasStream` directly (double dispatch).
- [ ] Gate: same + new unit tests for IqRequestManager.

## Phase 3 — AuthService decomposition (public API preserved)

- [ ] Split `connectXmpp` (1,122 lines) into `XmppSessionManager` + per-state wiring functions.
- [ ] Merge `auth_service_deps.dart` interfaces and legacy `XmppContactServiceDependencies` into one
      deps surface; sub-services stop writing `AuthService` private fields (emit events instead).
- [ ] Centralize duplicate mappings: presence enum maps, message-send OMEMO/OTR branches.

## Phase 4 — Call stack

- [ ] `CallProvider` → call state machine + per-transport controllers (Jingle/XMPP, SIP, Janus, mesh).
- [ ] Managed `WebRTCManager` factory; dedupe ICE fallback lists (also hardcoded openrelay creds → config).
- [ ] Throttle audio-level `notifyListeners()` fan-out.

## Phase 5 — UI

- [ ] `spaces_screen.dart` → `SpacesHubScreen` / `SpaceDetailView` / `CreatePostDialog` files.
- [ ] Shared widgets: markdown toolbar (3 copies), post cards (2 copies), attachment web-guards.
- [ ] Router: stop passing live services/models via `state.extra`; move to IDs/params (deep-link prep).

## Phase 6 — Data layer

- [ ] Repository layer over `DatabaseService` (25+ direct calls from `ChatProvider`/screens).
- [ ] Split UI-state vs persistence payload in `Conversation`; unify model JSON mapping.

## Notes

- `xmpp_stone` fork (packages/) is actively maintained locally (SM fix, SASL2, PingManager) — keep
  vendored. `sip_ua` is unmodified upstream — candidate for de-vendoring.
- Known code-hack hotspots for Phase 2+: `xmpp_proxy_service.dart` (STARTTLS strip/stream-feature
  rewriting), `file_stub.dart` (shadows Dart `File`), `// ignore: implementation_imports` reaches
  into xmpp_stone internals (`jingle_signaling_service.dart`, `http_upload_service.dart`).
- README claims "strictly a client"; app defaults to `https://gibberapp.online` backend — reconcile
  docs or config later (not a code refactor item).
- Hardcoded VAPID key + push API URL in `push_notification_web.dart` and ICE creds in
  `webrtc_manager.dart` — move to config in later phases.