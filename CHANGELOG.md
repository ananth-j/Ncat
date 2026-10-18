# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-10-18

### Added
- **Multi-Device Matrix & Per-Device Tabs**:
  - Independent `DeviceTabState` isolating search filters, package filters, and log buffers per serial.
  - Multi-screen grid mode (2–4 devices) with a strict hard cap of 2 concurrent real-time streams (`kMaxConcurrentStreams = 2`).
  - Bulk actions: "Screenshot All" (parallel captures across all connected devices) and "Mirror All".
- **Security Hardening**:
  - Origin validation on WebSocket upgrades and HTTP endpoints protecting against Cross-Site WebSocket Hijacking (CSWSH).
  - Cryptographically secure session token authentication (`--auth`, `--token <secret>`) for shared workstation safety.
  - Device serial format validation (`^[a-zA-Z0-9._:-]{1,64}$`) with dash-prefix rejection preventing command/flag injection.
  - POSIX shell escaping and control character sanitization in `sendInputText`.
  - Added comprehensive `SECURITY.md` vulnerability reporting policy and threat model documentation.
- **Real-Time Screen Mirroring & Low-Latency Input**:
  - Dedicated HTTP MJPEG stream (`/api/stream`) and WebSocket binary stream (`/stream`).
  - Interactive touch canvas with touch and drag event forwarding mapped from widget coordinates to physical device resolution.
  - Persistent `adb shell` process for sub-millisecond input injection (< 1ms latency).
  - Android soft-key navigation bar (Back, Home, Recents, Volume Up/Down, Power).
  - External hardware-accelerated `scrcpy` fallback button (`POST /api/scrcpy/launch`).
  - Single-frame memory hygiene with immediate `ui.Image.dispose()` preventing RAM drift.
- **Screenshot & Hardware Screen Recording**:
  - Native lossless PNG capture (`GET /api/screenshot`) with cross-platform download/saving.
  - Native hardware recording (`POST /api/record/start`, `POST /api/record/stop`) utilizing Android `screenrecord`.
  - Safe recording finalization via on-device `SIGINT` (`pkill -2 screenrecord`), waiting for MP4 container write before pulling.
  - Toolbar REC timer badge with 3-minute recording duration warning and auto-stop.
- **Logcat Virtualization & Ingestion Optimization**:
  - High-throughput virtualized table handling 100,000+ log lines at 60 FPS.
  - Incremental filtering with pre-calculated lower-case search tokens and regex evaluation.
  - Background mode: buffers logs in memory without rebuilding UI widgets when window is minimized or inactive.
  - `StringPool` deduplication for log tags and package identifiers.
- **Architecture & Infrastructure**:
  - Push-based `AdbTracker` listening to `adb track-devices` stream instead of polling timers.
  - Per-device `DeviceSession` isolation with automatic child process cleanup and orphan killer on startup.
  - `ProcessRunner` interface enabling 100% deterministic unit testing via `FakeProcessRunner`.
  - Loopback-only binding (`127.0.0.1`).
  - GitHub Actions CI workflow for format, analyze, and test.

---

## [0.1.0] - 2026-09-01
- Initial proof of concept logcat viewer with Dart bridge and WebSocket streaming.
