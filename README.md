<a href="https://play.google.com/apps/testing/com.gibber.desertrobotservices" target="_blank">
    <img src="https://images.squarespace-cdn.com/content/5c213a383c3a53bf091b1c36/74658c71-a6e5-494f-adcf-cda0d8173527/button-android-us.png?content-type=image%2Fpng" alt="Get it on Google Play" style="height: 60px; border-radius: 8px; transition: transform 0.2s; transform: scale(1);" onmouseover="this.style.transform='scale(1.05)'" onmouseout="this.style.transform='scale(1)'">
  </a>


[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/sethfox)


# 🌌 Gibber

![Flutter Version](https://img.shields.io/badge/Flutter-3.41.5-blue.svg?logo=flutter)
![Dart Version](https://img.shields.io/badge/Dart-3.11.3-blue.svg?logo=dart)
![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20Linux%20%7C%20Windows-lightgrey.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

## 🚀 Application Summary

**Gibber** is a modern, high-performance, and beautifully crafted unified communication client built natively with **Flutter** and **Dart**. 

Designed to break down walled gardens, Gibber acts as a universal bridge for disparate chat networks. It seamlessly integrates traditional protocols like **XMPP (Jabber)** alongside support architectures for IRC, Discord, and SIP/VoIP, aggregating all your conversations into a single, cohesive interface.

Unlike contemporary proprietary platforms, **Gibber is strictly a client application**. There is no centralized "Gibber Server" harvesting your data, nor is there a proprietary backend database. Gibber connects *directly* to standard, decentralized network servers (like `movim.eu` or your own self-hosted XMPP server), ensuring absolute data ownership, zero vendor lock-in, and uncompromising privacy for its users.

---

## 🌟 Why Gibber?

- **Uncompromised Privacy:** Your keys, your data. Gibber uses local SQLite databases and direct server connections.
- **Premium Design:** Say goodbye to utilitarian, boring open-source clients. Gibber features a dynamic glassmorphic UI, rich gradients, smooth micro-animations, and responsive layouts that look stunning on both mobile and desktop.
- **Always Connected:** Engineered with intelligent background persistence, Android WakeLocks, and desktop tray-minimization, Gibber ensures you never miss a critical message or incoming call.
- **High Fidelity:** From markdown rendering to WebRTC video calls, Gibber supports the rich features expected of a modern chat app without sacrificing its decentralized roots.

---

## STATE OF GIBBER.

Gibber is a mobile first application for xmpp. things are somewhat unstable in alpha release. most things work. If there are funds it will get development otherwise it is provided as is.


## ✨ Key Features

### 🌐 Multi-Protocol Connectivity
Gibber abstracts the complexities of different networks behind a unified, polished UI layer:
- **XMPP (Jabber):** First-class, modern XMPP support including Message Archive Management (MAM), Carbons, and PubSub.
- **Gateway & Transport Discovery:** Seamlessly map and connect to legacy networks (IRC) via XMPP transports.

### 🔒 Advanced Security & Encryption
Gibber guarantees message confidentiality across untrusted networks:
- **OTR (Off-the-Record):** Integrated OTR engine for highly secure, deniable, peer-to-peer messaging.
- **OMEMO:** Multi-end to multi-end encryption support for modern group chats and offline message security.
- **XEP-0392 Consistent Colors:** Cryptographically secure, deterministic avatar and username color generation to prevent identity spoofing.

### 📞 WebRTC Audio & Video Calling
Gibber features a robust, state-of-the-art WebRTC signaling engine built entirely in Dart.
- **Jingle (XEP-0166 / XEP-0353):** Standardized XMPP signaling for lightning-fast peer-to-peer media connections.
- **Trickle ICE & Early Media:** Lightning-fast connection establishment, incremental candidate gathering, and support for native ringback tones.

### 👥 Communities & Spaces (PubSub)
Discover, organize, and engage with global communities through Gibber's integrated Spaces module.
- **Unified Activity Feed:** An intelligent community feed that aggregates posts from subscribed spaces across multiple servers, backed by hyper-fast in-memory caching to eliminate load times.
- **Node Discovery:** Robust `disco#items` crawling to discover featured communities and rooms natively.
- **Rich Interaction:** Support for microblogging, threading, dynamic participant population in MUCs, and rich media sharing.

### 🎨 Premium UI / UX
- **Glassmorphism & Gradients:** Sleek aesthetics using dynamic blurs, rich themes, and high-contrast dark modes.
- **Responsive Layouts:** Seamless scaling from mobile screens to expansive desktop monitors with intelligent split-views.
- **Markdown & Rich Media:** GitHub-Flavored Markdown support with custom parsing for mentions, inline code, links, images, and voice notes.

---

## 🏗 Architecture & Tech Stack

- **Framework:** Flutter (Channel stable, ~3.41+)
- **Language:** Dart 3.11+
- **Database:** Embedded SQLite (`sqflite_ffi` for Desktop, standard `sqflite` for Mobile)
- **State Management:** Provider / Custom Listeners
- **Media Processing:** GStreamer (Linux desktop), `record`, `audioplayers`
- **Networking Engine:** Raw TCP/TLS Sockets, custom robust protocol parsers.

### Core Services
The application logic is cleanly decoupled into specialized services:
- `AuthService`: Manages network connections, Presence stanzas, and protocol lifecycles.
- `JingleSignalingService`: The decentralized brain behind WebRTC media negotiation.
- `SpacesService`: Handles PubSub subscriptions, community discovery, and in-memory feed caching.
- `OtrEngine`: Pure Dart implementation of the OTR encryption protocol.

---

## 🚀 Getting Started

### Prerequisites
1. **Flutter SDK:** Ensure you have the Flutter SDK installed (`v3.41.5`) and added to your `PATH`.
2. **Native Build Tools:**
   - **Linux:** `ninja-build`, `libgtk-3-dev`, `pkg-config`, `cmake`, `clang`, `libgstreamer1.0-dev`, `llvm-18`.
   - **Android:** Android Studio and appropriate NDKs.
   - **Windows:** Visual Studio 2022 with C++ workload.

### Installation & Build

1. **Clone the repository and fetch dependencies:**
   ```bash
   flutter pub get
   ```

2. **Run on Desktop (Debug):**
   *(Note: Due to C++ standard library linking on certain Linux setups, you may need to export include paths prior to building)*
   ```bash
   export CPLUS_INCLUDE_PATH="/usr/include/c++/13:/usr/include/x86_64-linux-gnu/c++/13"
   flutter run -d linux
   ```

3. **Run on Android:**
   ```bash
   flutter run -d android
   ```

4. **Testing:**
   ```bash
   flutter test
   ```

---

## 🛠 Known Gotchas & Troubleshooting

- **Linux Release Builds:** `flutter build linux` (release) may fail with permission errors if attempting to install directly to `/usr/local/`. Use `--debug` or `flutter run -d linux` for development.
- **C++ Headers:** The `flutter_webrtc` plugin on Linux requires LLVM/Clang and standard library headers. Ensure `libstdc++.so` is correctly symlinked if linking errors occur.
- **Testing Constraints:** Some widget tests intentionally fail due to legacy codebase mismatch assertions (e.g., database context loading). Core network tests (`omemo_test.dart`, `call_test.dart`, `simple_test.dart`) run successfully.
- **No Local Server Needed:** Remember, Gibber is a *client*. It does not require you to host a backend server or database. Simply point it at your favorite XMPP domain and log in.

---

## 📜 License
This project is licensed under the MIT License - see the LICENSE file for details.
