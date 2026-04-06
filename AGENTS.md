# Agents

## Cursor Cloud specific instructions

### Project overview

Gibber is a multi-protocol messaging and calling client built with **Flutter/Dart**. It supports XMPP, IRC, Discord, and SIP/VoIP. It is a single Flutter application (no backend services, no monorepo).

### Prerequisites (system-level, already installed in the VM snapshot)

- **Flutter SDK 3.41.5** (Dart 3.11.3) at `/opt/flutter/bin` (added to `PATH` via `~/.bashrc`)
- **Linux desktop build deps**: `ninja-build`, `libgtk-3-dev`, `pkg-config`, `cmake`, `clang`
- **GStreamer dev**: `libgstreamer1.0-dev`, `libgstreamer-plugins-base1.0-dev` (required by `audioplayers_linux`)
- **LLVM toolchain**: `llvm-18`, `lld` (required by `flutter_webrtc` native build)
- **libstdc++ symlink**: `/usr/lib/x86_64-linux-gnu/libstdc++.so` → gcc-13 (clang needs this for linking)

### Common commands

| Task | Command |
|---|---|
| Install deps | `flutter pub get` |
| Lint / analyze | `flutter analyze` |
| Run tests | `flutter test` |
| Build Linux debug | `flutter build linux --debug` |
| Run Linux desktop | `flutter run -d linux` |
| Run on Chrome | `flutter run -d chrome` |

### Gotchas

- **C++ include path**: When building the Linux desktop app, clang may not find C++ standard library headers. Set `export CPLUS_INCLUDE_PATH="/usr/include/c++/13:/usr/include/x86_64-linux-gnu/c++/13"` before building.
- **`flutter build linux` (release)** fails with a permission error trying to install to `/usr/local/`. Use `flutter build linux --debug` or `flutter run -d linux` for development.
- **Tests**: Some widget tests fail with pre-existing issues (app title mismatch, database factory not initialized in test context). These are codebase issues, not environment issues. The `simple_test.dart`, `omemo_test.dart`, `backup_test.dart`, and `call_test.dart` tests pass (4 pass, 8 fail as of current main).
- **No external servers needed for dev**: The app is a client that connects to external XMPP/IRC/Discord servers. No local backend or database setup is required. SQLite is embedded.
