# Agent Guidelines for Flutter Chat Application

## Project Overview
This is a Flutter chat application with XMPP and IRC support using pure Dart libraries (`xmpp_stone` and `irc_dart`). The application features a tabbed interface with custom magenta and turquoise Material Design theme.

## Build, Lint, and Test Commands

### Build Commands
```bash
# Build for Linux (development)
flutter build linux

# Build for Linux (release)
flutter build linux --release

# Build APK for Android
flutter build apk --release

# Build app bundle for Android
flutter build appbundle --release

# Build for web
flutter build web

# Build for iOS
flutter build ios --release
```

### Lint Commands
```bash
# Run static analysis
flutter analyze

# Run lints with detailed output
flutter analyze --fatal-infos --fatal-warnings

# Fix automatically correctable lint issues
flutter format lib/ test/
```

### Test Commands
```bash
# Run all tests
flutter test

# Run tests with verbose output
flutter test -v

# Run a single test file
flutter test test/widget_test.dart

# Run tests matching a name pattern
flutter test -name "smoke test"

# Run tests with coverage
flutter test --coverage

# View coverage report
genhtml coverage/lcov.info -o coverage/html
```

### Hot Reload/Restart During Development
```bash
# Run in debug mode (for hot reload)
flutter run -d linux

# Hot reload (press 'r' in terminal)
# Hot restart (press 'R' in terminal)
```

## Code Style Guidelines

### Import Organization
1. **Standard library imports** first (dart:*)
2. **Package imports** second (package:*)
3. **Relative imports** third (./, ../)
4. **Blank line** between each group
5. **Alphabetical sorting** within each group

Example:
```dart
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'package:irc_dart/irc_dart.dart';

import './local_widget.dart';
```

### Formatting
- Use `flutter format` command to automatically format code
- Maximum line length: 100 characters (Flutter default)
- Use 2 spaces for indentation (not tabs)
- Trailing commas are preferred for better formatting

### Types and Variables
- Use explicit types for public APIs and return types
- Use `var` for local variables when type is obvious
- Use `final` for variables that don't change after initialization
- Use `const` for compile-time constants
- Avoid `dynamic` unless absolutely necessary

### Naming Conventions
- **Classes**: PascalCase (e.g., `ChatHomePage`)
- **Variables and functions**: camelCase (e.g., `_isXmppConnected`, `_addXmppMessage`)
- **Constants**: lowercase_with_underscores (e.g., `maxMessageLength`)
- **Enums**: PascalCase for enum name, camelCase for values
- **Files**: snake_case (e.g., `main.dart`, `chat_service.dart`)
- **Libraries**: Follow package naming conventions
- **Private members**: Prefix with underscore (`_`)

### Error Handling
- Use try/catch for asynchronous operations that can fail
- Provide meaningful error messages to users
- Log errors appropriately for debugging
- Don't ignore exceptions with empty catch blocks
- Consider using `Future.error()` for propagating errors in async APIs

Example:
```dart
try {
  await _xmppConnection!.connect();
} catch (e) {
  _addXmppMessage("XMPP connection error: $e", isSent: false);
  rethrow; // Optional: propagate if caller should handle
}
```

### Comments and Documentation
- Use `///` for documentation comments (generates documentation)
- Use `//` for inline comments
- Document all public APIs with doc comments
- Explain why, not what (unless the what is non-obvious)
- Keep comments up-to-date when code changes

### Widget Construction
- Prefer `const` constructors when possible
- Extract complex UI into separate widgets
- Use `const` for immutable widgets
- Keep build methods pure (no side effects)
- Use `Expanded` and `Flexible` for flexible layouts
- Consider using `Consumer` or similar for state management

### Asynchronous Programming
- Use `async/await` for readable asynchronous code
- Avoid blocking the UI thread with synchronous operations
- Handle futures properly (don't ignore them)
- Use `Completer` when needed for complex async flows
- Cancel subscriptions in `dispose()` to prevent memory leaks

### State Management
- Use `setState()` for simple state updates
- Consider state management solutions (Provider, Riverpod, Bloc) for complex state
- Keep state immutable when possible
- Initialize state in `initState()` or constructor
- Clean up resources in `dispose()`

### Security Considerations
- Never hardcode sensitive information (passwords, keys)
- Use secure storage for credentials (flutter_secure_storage)
- Validate all inputs (especially for network operations)
- Use HTTPS/TLS for network communications
- Be careful with logging sensitive information

### Performance
- Use `const` widgets where possible
- Avoid rebuilding widgets unnecessarily
- Use `ListView.builder` for long lists
- Consider using `RepaintBoundary` for complex animations
- Profile performance with Flutter DevTools

## Project-Specific Guidelines

### XMPP/Irc Implementation
- Handle connection states properly (connecting, connected, disconnected, error)
- Use appropriate XMPP/JID handling with the xmpp_stone library
- Follow IRC protocol specifications for message formatting
- Implement proper reconnection logic
- Handle message parsing safely (null checks)

### UI/UX Guidelines
- Use the defined magenta (#E91E63) and turquoise (#00BCD4) color scheme
- Provide visual feedback for user actions
- Ensure accessible color contrast
- Follow Material Design 3 guidelines
- Use appropriate spacing and typography
- Handle different screen sizes and orientations

### Resource Management
- Cancel all stream subscriptions in `dispose()`
- Dispose controllers (TextEditingController, etc.)
- Close connections properly
- Remove listeners to prevent memory leaks
- Use `?.` null-aware operators when disposing nullable resources

## Directory Structure Guidelines
- `lib/`: Main application code
  - `main.dart`: Entry point
  - Feature-based organization as app grows
- `test/`: Test files
  - Unit tests
  - Widget tests
  - Integration tests (when added)
- `assets/`: Images, fonts, etc. (when added)
- Platform-specific directories (`android/`, `ios/`, etc.): Generally avoid modifying unless necessary

## Commit Message Guidelines
- Use present tense ("Add feature" not "Added feature")
- Keep subject line under 50 characters
- Include motivation for change in commit message
- Reference issue numbers if applicable
- Separate subject from body with blank line

Example:
```
Fix XMPP connection handling

Fix race condition where connection state could be missed
during rapid connect/disconnect sequences. Add proper state
tracking and ensure message handler is only initialized once.
```

## Troubleshooting Common Issues

### Build Failures
1. Run `flutter pub get` to ensure dependencies are installed
2. Check Dart SDK version compatibility
3. Verify Android/iOS toolchain setup
4. Clean build: `flutter clean` then rebuild

### Runtime Errors
1. Check console output for error messages
2. Verify plugin compatibility with target platform
3. Check null safety issues (especially with newer plugins)
4. Use Flutter DevTools for debugging UI issues

### Test Failures
1. Ensure test environment matches expectations
2. Check for asynchronous timing issues
3. Verify mock behavior if using mocks
4. Look for state leakage between tests

## VOIP Calling Debugging Notes

### Current Status (April 2026)

Working on fixing VOIP audio calling through cheogram.com XMPP gateway. **Progress: Audio path now established, but user cannot hear remote party.**

## Progress Summary

### Completed Fixes
1. **ICE Timeout Fix**: Cancel timeout when remote track is received (not just when ICE connects)
2. **ICE Debug Timer Fix**: Don't restart ICE for active calls (media is flowing!)
3. **Duplicate session-accept prevention**: Added `_remoteAnswerProcessed` flag
4. **Audio-only SDP generation**: `offerToReceiveVideo: false` for voice calls
5. **BUNDLE mismatch fix**: Handle remote SDP with video in BUNDLE but no m=video line
6. **SIP null pointer fix**: Added `transportType = TransportType.WS`
7. **SIP URI fix**: Now passing `sip:seth@cleanglovesolutions.com` instead of just `sip:seth`
8. **Speaker forced ON**: For voice calls, speaker is enabled by default

### Current Issue: Audio NOT Playing on Remote Side

**Symptoms**: Remote track IS received (`WebRTC: Track received - kind: audio`), audio stats show inbound audio, but user cannot hear the remote party.

**Debug logs to look for**:
```
CallProvider: ========== CALL PROVIDER ON TRACK ==========
CallProvider: === REMOTE TRACK RECEIVED ===
CallProvider: Stream id: xxxxxxxxx
CallProvider: Stream active: true
CallProvider: Stream audio tracks: 1
CallProvider: Remote renderer srcObject set: true
CallProvider: [DELAY 200ms] Stream still attached, audio should be playing
```

**Possible causes**:
1. `RTCVideoView` not properly playing audio on mobile for audio-only streams
2. Audio routing issue (going to earpiece instead of speaker)
3. Audio session conflict with other apps
4. Android audio focus not properly acquired

### Key Files Modified
- `lib/services/webrtc_manager.dart` - WebRTC peer connection management
  - `onTrack` callback: Enhanced logging for audio track state
  - `ensureAudioEnabled()`: Re-enables audio tracks
  - `_remoteStream` storage for remote audio

- `lib/providers/call_provider.dart` - Call state management
  - `_setupRtcListeners()`: Multiple delayed audio fixes for Android
  - `onTrack` callback: Enhanced logging, speaker forcing, volume setting
  - `acceptCall()`: ICE timeout only fails if no media received

- `lib/screens/call_screen.dart` - Call UI
  - `RTCVideoView`: Rendered when stream exists for audio playback
  - Debug logging for stream audio/video track counts

### Technical Details

**Why ICE stays in "Checking" but media works**:
- cheogram.com gateway uses internal IPs that aren't reachable externally
- BUT: The gateway's SIP infrastructure routes media directly
- When remote track is received, media IS flowing through the gateway
- The issue is just the user-facing audio playback, not the media path

**Audio path**:
1. Remote audio → Gateway → Our app (WebRTC receives this)
2. WebRTC `onTrack` event fires with audio track
3. `RTCVideoView` should play audio through speaker
4. User should hear audio

**What's likely broken**:
- `RTCVideoView` audio element not created/playing
- OR: Audio going to wrong output device (earpiece instead of speaker)
- OR: Android audio session not properly configured

### Next Steps

1. **Test with detailed logging**: Get logs showing all audio operations
2. **Verify speaker output**: Check if `Helper.setSpeakerphoneOn(true)` is working
3. **Try alternative audio approach**: Use explicit `AudioElement` or audio sink
4. **Check RTCVideoView**: Ensure it creates audio element for audio-only streams
5. **Android audio session**: Verify `inCommunication` mode is active

### Root Cause (ICE)

**The cheogram.com gateway does NOT provide TURN/relay candidates.**

From the debug logs:
- Our app generates: `candidate:4140738488 1 udp 41886463 51.222.159.117 63502 typ relay`
- Gateway provides ONLY: `candidate:1393072040 1 udp 2130706431 10.0.3.1 11182 typ host`

The gateway's internal IPs (`10.0.3.1`, `192.168.122.1`, `51.161.87.91`) are NOT reachable from outside the gateway's network. Without relay candidates, WebRTC ICE cannot establish a connection when:
- The remote phone endpoint is behind NAT/firewall
- The remote phone endpoint is on a different network

However, media still flows through the gateway's SIP infrastructure, which is why we receive the remote track.

### SIP Status

**SIP WebSocket connection to cheogram.com:10443 is being refused** - Network-level connection refused error. This is a firewall/network issue, not a code issue.

The XMPP Jingle path is the primary path and it works (media flows), but the audio isn't being heard.

### Potential Solutions to Try
1. **Add explicit audio logging**: Verify audio element is created and playing
2. **Try different audio widget**: Use `Audio` from flutter_webrtc instead of RTCVideoView
3. **Check Android audio routing**: Add native logging for audio output device
4. **Test with another XMPP client**: Verify if cheogram works with Conversations
5. **Alternative gateway**: Consider `jmp.chat` which provides TURN servers