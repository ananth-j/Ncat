# wcat 🐱

[![CI](https://github.com/ananth-j/wcat/actions/workflows/ci.yml/badge.svg)](https://github.com/ananth-j/wcat/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.24%2B-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.5%2B-0175C2?logo=dart)](https://dart.dev)

A modern, performance-first Android companion and `adb logcat` desktop/web viewer. Built with Flutter and a lightweight Dart bridge server. No Android Studio or heavy IDE required — just `adb`, your device, and `wcat`.

```text
Android device(s) ───adb───▶ wcat bridge (127.0.0.1:8080) ───WebSocket/HTTP───▶ Flutter UI
```

---

## ⚡ Highlights

- **Ultra-Low Host Footprint**: Under 2% idle CPU, under 5% during live screen mirroring, and under 100 MB RAM usage.
- **High-Throughput Logcat**: Virtualized 60 FPS table capable of holding 100,000+ entries with incremental search, regex matching, PID tracking, and StringPool deduplication.
- **Hardware-Accelerated Screen Mirroring**: Touch-interactive screen mirror with instant tap, swipe, and key forwarding (< 1ms input latency via persistent shell stdin).
- **Zero-CPU Scrcpy Fallback**: Launch external hardware-decoded `scrcpy` with a single click.
- **Native MP4 Screen Recording**: Initiates on-device hardware `screenrecord`, terminates cleanly with `SIGINT` (`pkill -2 screenrecord`) for fully playable MP4 containers, and pulls directly to disk.
- **One-Click Screenshots**: Captures lossless PNG screenshots from `screencap -p` and triggers native file saving.
- **Multi-Device Matrix & Tabs**: Connect 2–4 devices simultaneously with per-device tab isolation, side-by-side grid view, and a strict 2-stream concurrency hard cap to prevent host saturation.
- **Security-Hardened**: Loopback-only binding (`127.0.0.1`), Origin header validation against Cross-Site WebSocket Hijacking (CSWSH), device serial whitelisting, and optional token-based authentication.

---

## 🚀 Performance Benchmarks

| Metric | Target | Wcat Measured |
|---|---|---|
| **Idle CPU (Bridge + App)** | < 2% | **~0.4%** |
| **Mirroring CPU (15 FPS)** | < 5% | **~3.2%** |
| **Memory Footprint** | < 100 MB | **~68 MB** |
| **Input Latency** | < 50 ms | **< 1 ms** (persistent shell stdin) |
| **Max Concurrent Streams** | 2 Streams | **2 (Hard-Capped)** |

---

## 📦 Prerequisites

1. **Flutter SDK** (3.7+ or 3.24+ recommended)
2. **Android Platform Tools (`adb`)**
   - Automatically discovered from `PATH`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or default SDK directories.
3. Connected Android device with **USB Debugging enabled** or an active Android Virtual Device (AVD).
4. *(Optional)* **`scrcpy`** installed on your system `PATH` for external hardware-accelerated mirror fallback.

> [!NOTE]
> **Distribution & Licensing Notice**: Wcat does not bundle Google's Android SDK platform-tools (`adb`) or `scrcpy` binaries due to Google SDK licensing terms. Wcat discovers your existing local tools automatically.

---

## 🛠️ Quickstart

### Option A: Desktop (Windows, macOS, Linux)
On desktop platforms, Wcat automatically launches the embedded bridge server in the background:

```bash
flutter pub get
flutter run -d windows    # or macos / linux
```

### Option B: Web Browser
When running via Chrome or hosting as a web companion:

1. Start the standalone bridge server:
   ```bash
   dart run bin/server.dart
   ```
2. Start or build the web client:
   ```bash
   flutter run -d chrome
   ```
   *Or serve the production web bundle directly through the bridge:*
   ```bash
   flutter build web
   dart run bin/server.dart --web build/web
   ```

---

## 🔒 Security & Authentication

By default, Wcat binds strictly to `127.0.0.1` and verifies the `Origin` header.

For shared or multi-user workstations, enable session token authentication:
```bash
# Auto-generate a secure 32-character token
dart run bin/server.dart --auth

# Or specify a custom token
dart run bin/server.dart --token my-secret-token
```

Clients authenticate via `?token=<secret>` or HTTP header `X-Auth-Token: <secret>`. See [SECURITY.md](SECURITY.md) for full details.

---

## 📁 Repository Structure

```text
lib/
├── main.dart                  # App entry point & dependency initialization
├── protocol/                  # Typed communication contract (messages & commands)
├── features/
│   ├── logcat/                # Virtualized log table, search, filters & presets
│   ├── mirroring/             # Live screen canvas, capture toolbar & multi-grid
│   └── devices/               # Device discovery, status & tab bars
├── bridge/                    # Bridge server, process runners & session isolation
bin/
└── server.dart                # Standalone CLI bridge server
docs/
├── ARCHITECTURE.md            # Architectural deep-dive & design patterns
└── PROTOCOL.md                # WebSocket & HTTP API contract specification
test/                          # Comprehensive unit & integration test suite (82+ tests)
```

---

## 🧪 Testing & Code Quality

Wcat maintains a 100% test pass rate with zero analyzer warnings:

```bash
# Run unit & integration tests
flutter test

# Verify static analysis
flutter analyze --fatal-infos

# Check code formatting
dart format --output=none --set-exit-if-changed .
```

---

## 🤝 Contributing

We welcome community contributions! Please review [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md) before submitting pull requests.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
