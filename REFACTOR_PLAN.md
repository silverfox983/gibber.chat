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

- [x] Remove dead chat block in `main_chat_screen.dart` — done in `b597336`: deleted
      `_buildChatContent` cascade, unused media/voice/upload helpers, duplicate forward dialogs,
      Mention helper classes, dead dial-pad pair (`_dialButton`/`_formatDialedNumber`),
      `HighlightedText`, and 25 orphaned imports. 4,491 → 874 lines.
- [x] Remove dead `ChatMessage.senderColor` — kept as-is (pending Phase 6 model split; harmless).
- [x] Drop vendored `packages/sip_ua` (unmodified upstream 1.1.0) → revert to pub dependency.
- [x] Gate: core tests all pass; analyzer errors stay at 0; warnings reduced.

## Phase 2 — Shared XMPP infrastructure  ✅

- [x] `IqRequestManager`: shared request/response correlation (lib/services/iq_request_manager.dart,
      8 unit tests). Converted all 10 services that each carried a private `_pendingIqs` map:
      pep, server_info, sticker, pubsub_interaction, channel-search, transport, spaces,
      registration, room, auth (`2bf1cbc`, `f18299e`, `20d7b8f`).
- [x] Single stanza dispatch bus: AuthService's central `inStanzasStream` listener routes every
      stanza to per-account `SpacesService.handleStanza`; SpacesService no longer subscribes to
      the connection itself, its `accountId` is now a ctor argument, reverse-lookup mapper
      closures deleted (`e2687ec`).
- [x] `XmppSessionLookup` + `XmppSession` (lib/services/xmpp_session_lookup.dart):
      XmppRoomService now resolves connections/JIDs through the lookup instead of holding
      references to AuthService's mutable maps; `setActiveAccountIdGetter` hook removed
      (`e5f0c0x`). Ready as groundwork for Phase 3's session manager.
      Note: room-service `_discoveryCompleters`/`_roomInfoCompleters` and their auth-side
      twins remain (typed correlation, not IQ plumbing) — candidate for a follow-up generic
      CompleterMap helper.
- [x] Gate: core tests all pass ("+12"), analyzer 0 lib errors.

## Phase 3 — AuthService decomposition (public API preserved)  ✅

- [x] `connectXmpp` no longer contains the giant nested listeners:
  - state listener body → `_onXmppConnectionState` (verbatim, `7d98799`)
  - stanza dispatcher body (~770 lines) → `_dispatchXmppStanza` (`e76d0f3`)
  - roster listener → `_handleRosterItems`; presence listener → `_handlePresenceUpdate`
    (typed `xmpp.Buddy` / `xmpp.PresenceData`) (`c2e6f32`)
- [x] `XmppSessionLookup` implemented by AuthService (Phase 2 groundwork).
- [x] Ready-branch service setup (ping/omemo/presence/jingle/upload/discovery/sync/push)
      → `_setupAccountServices` (`71bb458`).
- [x] `CompleterMap<T>` generalizes IqRequestManager; auth's `_discoveryCompleters`/`_roomInfoCompleters`
      and room-service twins migrated to it; fallback completion chains collapsed
      (`d7b1bf4`, +5 unit tests `0a4b5c6`).
- [x] Legacy `XmppContactServiceDependencies` snapshot layer deleted — XmppContactService uses the
      abstract `AuthServiceContactDeps` directly; this also repairs latent crashes where the
      service mutated the ctor-time unmodifiable snapshot (import/rename/remove contact paths)
      (`8ab3f67`, `73fe3e3`).
- [x] Shared presence mapping (`presence_mapping.dart`) replaces duplicated
      `_mapShowToPresence`/`_mapPresenceToShow`/dead `mapPresenceToShow` (`d39173f`).
- [x] Deps write-back setters eliminated — replaced with intent-revealing interface methods
      (`updatePresenceStatus`, `reportDiagnostic`, `reportStreamError`, `updateCurrentProfile`);
      6 dead setter declarations removed; sub-services no longer write AuthService private fields
      through the deps surface (`cc3fa98`, `17b9c46`).
- [x] Single `_decryptOmemoBody` helper replaces 4 duplicated OMEMO decrypt/rebuild/placeholder
      blocks in the stanza handler (`a6e2c4b`).
- Known follow-ups (not blockers): `_parseSfs` in stanza handler is unwired feature code from
  the XEP commit — wire it when SFS ingest lands (Phase 5/6); OMEMO/OTR send branches in
  XmppMessageService still have separate paths — candidate for later consolidation.

## Phase 4 — Call stack  — in progress

- [x] Shared `ice_config.dart`: single source for the ICE fallback list + default RTC
      configuration; duplicated constants deleted from both WebRTC managers (`747c4dd`).
      Hardcoded openrelay creds still live there pending backend `iceServers` provisioning.
- [x] PSTN gateway detection extracted to `lib/utils/pstn_gateway.dart` (+4 unit tests, `9158add`);
      gateway-routing send logic consolidated into `_sendJingleInitiateViaAppropriateChannel` /
      `_sendSessionAcceptViaAppropriateChannel` (4 sites deduped; 500ms ICE-gathering grace for
      gateways preserved) (`0a487c2`).
- [x] Managed manager lifecycle: `_resetRtcManager()` / `_resetMultiPeerManager()` consolidate the
      5 duplicated dispose+recreate sites, disposing before recreating (`45af99d`).
- [x] `_jingleSignaling(accountId)` accessor replaces 13 duplicated
      `getJingleService(accountId ?? '') ?? jingleSignaling` fallback expressions (`6e9efa8`).
      Note: sites pass their own account id verbatim so per-account resolution semantics are
      byte-identical (event.accountId site intentionally has no `_callAccountId` fallback).
- [x] Audio-level `notifyListeners()` throttled in a single shared `_onRtcAudioLevels`
      (value change ≥0.05, talk-while-muted flag change, or 150ms cadence — previously every
      stats tick rebuilt the whole app; 3 duplicated listeners deleted) (`843a025`).
- [x] `_setupRtcListeners` split: ICE watchdog stays inline; `onTrack` → `_onRtcRemoteTrack`
      (media-established transition + Android audio-fix cascade), `onConnectionState` →
      `_onRtcConnectionState` (disconnect grace), `onIceConnectionState` →
      `_onRtcIceConnectionState` (restart state machine), `onIceCandidate` →
      `_onRtcIceCandidate` (gateway-routed trickle). Orchestrator ~50 lines, callbacks
      individually reviewable (`7a5ef5b`).
- [ ] Full split by transport: `XmppCallController` / `SipCallController` / `GroupCallController`
      (Janus + mesh). Keep `CallProvider` as state/notifier façade. Note: `_initializeSipService`
      and `_setupJanusListeners` touch 8+ provider fields (state, renderers, timers, cleanup) —
      controller extraction should happen in one focused session with the call flow exercised
      manually on device (weak automated coverage for SIP/Janus paths).

## Phase 5 — UI  — in progress

- [x] `spaces_screen.dart` split (4,467 → hub 1,438 / detail 2,561 / dialog 446)
      (`c2411f2`): `SpaceDetailView` + `SpacesScreenManager` → `lib/screens/space_detail_view.dart`,
      `CreatePostDialog` → `lib/widgets/create_post_dialog.dart`; router imports updated;
      per-file unused imports trimmed.
- [x] Markdown toolbar: only ONE copy remains (create_post_dialog) — the other two copies
      were inside the dead code deleted in Phase 1 (main_chat_screen) or never had helpers
      (feed composer renders `MarkdownBody` only). No dedupe needed.
- [ ] Post-card duplication (feed `_buildSpaceItemCard` vs detail `_buildPostCard`) — real
      unification requires reconciling interaction-state differences between contexts; needs
      visual verification on device/screenshots. Deferred deliberately.
- [ ] Attachment web-guards: 2 remaining copies differ only by image height — trivial inline
      conditionals, extraction would over-abstract. Closed as no-op.
- [x] Router: live services removed from `state.extra` — the 5 Spaces routes resolve the cached
      per-account `SpacesService` via the router's `AuthService` (non-null guaranteed by the
      auth redirect); 5 push sites simplified. Remaining extras are data payloads (space/post/
      conversation objects) — ID-based resolution belongs to the deferred deep-link work below.
- [x] Discovered: `articleView` route is never navigated to (defined + screen, zero push sites).
      Left in place until SFS/article feature wiring (matches `_parseSfs` story).
- [ ] Wire SFS ingest (`_parseSfs`) into the message pipeline.

## Phase 6 — Data layer  — in progress

- [x] `ChatProvider` now receives its `DatabaseService` via constructor injection
      (default unchanged for production); all 23 singleton-factory reach-ins removed (`4fa3dcf`).
- [x] `DatabaseService.forTest(path)` factory — per-instance isolated DBs (sqflite path-cache
      makes `:memory:` non-isolating across instances; tests use distinct temp files).
- [x] +3 integration tests (`chat_provider_db_test.dart`): provider persists through the injected
      instance; separate injected instances do not share rows; fresh provider starts empty.
- [ ] Remaining `DatabaseService()` reach-ins to inject the same way (each touches service ctor
      wiring — one service at a time): auth_service (4), xmpp_contact_service (4),
      chat_settings_screen (2), xmpp_stanza_handler (1), account_preferences_screen (1),
      offline_queue_service (1).
- [ ] Model split: UI-state vs persistence payload in `Conversation` (typing flags, unread
      count live alongside DB row mapping); unify reaction key ('reactions_json' + 'reactions'
      dual write in ChatMessage.toMap).
- [ ] Repository abstraction (mock-able chat repo) — deferred until provider tests need a fake;
      injection point now exists.

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