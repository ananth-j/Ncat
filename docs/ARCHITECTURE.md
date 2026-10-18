# Wcat Architecture Specification

`wcat` is a high-performance, low-overhead Android companion tool designed for streaming and filtering `adb logcat`, capturing low-latency screen video, injecting touch/key events, and recording device video across multiple devices.

---

## 1. High-Level System Overview

```
┌────────────────────────────────────────────────────────┐
│                   Flutter Frontend                     │
│  (Desktop: Windows / macOS / Linux  |  Web: Browser)   │
└───────────────▲────────────────────────▲───────────────┘
         Control & Logs (WS)         Video Stream (HTTP / WS)
         JSON Batches / 100ms        Single-Frame ui.Image
                │                                │
┌───────────────▼────────────────────────────────▼───────┐
│                  Dart Bridge Server                    │
│   (Loopback 127.0.0.1 : 8080 | Embedded or Standalone) │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │           AdbTracker (Push-based)                │  │
│  │  Streams `adb track-devices` for real-time plug  │  │
│  └──────────────────────────────────────────────────┘  │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │         DeviceSession (Per-Device Serial)        │  │
│  │  - Isolated ring buffer (100,000 lines)          │  │
│  │  - Dedicated `adb logcat -v epoch` process       │  │
│  │  - Persistent `adb shell` for < 1ms input        │  │
│  │  - Native `screenrecord` with SIGINT finalizer   │  │
│  │  - On-demand screencap frame streamer            │  │
│  └──────────────────────────────────────────────────┘  │
└───────────────────────────▲────────────────────────────┘
                            │
               Native Subprocesses (ADB CLI)
                            │
┌───────────────────────────▼────────────────────────────┐
│               Android Device / Emulator                │
└────────────────────────────────────────────────────────┘
```

---

## 2. Core Architectural Principles

### 2.1 The "Dumb Pipe" Host Principle
Video transcoding on the host CPU is computationally expensive. Wcat treats the Dart bridge as a **dumb pipe**:
- The bridge never runs ffmpeg, OpenCV, or software video re-encoding on the host.
- Video recording uses the device's native hardware encoder (`screenrecord`). The bridge sends `SIGINT` (`pkill -2 screenrecord`) on the device, waits for MP4 container finalization, and pulls the completed MP4.
- High-framerate mirroring offers two modes:
  1. **Hardware-Accelerated Fallback**: Launch `scrcpy` in an external window (`POST /api/scrcpy/launch`), consuming 0% host CPU.
  2. **Embedded Passthrough**: Streams lightweight PNG frames on demand via `exec-out screencap -p`, with framerate clamping (5/15/30 fps) and immediate texture disposal on the client.

### 2.2 Stream Separation
High-frequency video frames and low-frequency text logs are strictly isolated:
- **Logcat & Control**: Batched JSON messages over `ws://127.0.0.1:8080/ws` flushed every 100ms.
- **Screen Mirror**: Dedicated stream over `GET /api/stream?serial=XYZ` (MJPEG) or `/stream` (WebSocket binary). Video data never blocks or creates backpressure on logcat ingestion.

### 2.3 Strict Session Isolation
All device state is encapsulated in `DeviceSession`:
- No global device assumptions.
- Each device maintains its own process handles, PID resolution, package filters, log buffer, and recording state.
- Disconnecting a device automatically cancels all associated streams and kills child processes.

---

## 3. Layer Breakdown

### 3.1 Presentation Layer (`lib/features/`)
- **`logcat/`**: Virtualized, high-throughput log viewer (`LogTable`). Built with custom layout renderers to handle 100,000+ lines at 60fps.
- **`mirroring/`**: Touch-aware interactive canvas (`ScreenMirrorView`) wrapped in a `RepaintBoundary` to prevent log table repaints during video playback.
- **`devices/`**: Multi-device tab bar (`DeviceTabBar`) and multi-screen grid layout (`MultiScreenGrid`).

### 3.2 State & Controller Layer
- **`LogcatController`**: Manages view state, search queries, severity filters, column configuration, and per-device tab state (`DeviceTabState`). When the app is minimized or hidden, it enters **Background Mode**, buffering logs in memory without rebuilding the UI widget tree.
- **`MirrorController`**: Manages stream subscription lifecycle, coordinate scaling (widget space to physical device resolution), touch event dispatch, and single-frame texture lifecycle.
- **`CaptureService`**: Coordinates single-shot screenshots and hardware video recording with toolbar badge countdowns.

### 3.3 Bridge Management (`lib/bridge/`)
- **Conditional Compilation**: Uses Dart conditional imports (`bridge_manager_io.dart` vs `bridge_manager_stub.dart`) so the app compiles seamlessly to native desktop executables and pure Web (WASM/JS).
- **Desktop**: Automatically spawns and manages `LogcatBridgeServer` inside the application process.
- **Web**: Connects to the standalone bridge server via WebSocket/HTTP on `localhost:8080`.

### 3.4 Process & ADB Runner Layer (`lib/bridge/server/runners/`)
- **`ProcessRunner` Interface**: Abstraction over `dart:io Process` allowing complete unit and integration testing without requiring real hardware or ADB binaries via `FakeProcessRunner`.
- **`AdbTracker`**: Listens to `adb track-devices` stdout rather than polling `adb devices` on a timer, eliminating idle process fork overhead.

---

## 4. Performance & Memory Engineering

| Constraint | Strategy |
|---|---|
| **< 2% Idle CPU** | Push-based `track-devices`, periodic flush timer (100ms), no busy loops or polling. |
| **< 5% Mirror CPU** | Host never encodes video; client clamps framerate and disposes previous `ui.Image` immediately on new frame arrival. |
| **< 100MB RAM** | Global `StringPool` deduplicates repeated log tags and package strings. Inverted index for O(1) incremental filter evaluation. |
| **Multi-Stream Hard Cap** | Strict 2-stream active cap (`kMaxConcurrentStreams = 2`). Other grid tiles display static thumbnail snapshots. |
| **Zero Input Latency** | One persistent `adb shell` process per device session; commands written directly to stdin (`writeln`) reducing tap latency from ~250ms to < 1ms. |

---

## 5. Security Architecture

1. **Loopback Only**: Server binds exclusively to `InternetAddress.loopbackIPv4` (`127.0.0.1`).
2. **CSWSH Defense**: Checks the HTTP `Origin:` header to block cross-origin browser requests from external websites.
3. **Serial Whitelisting**: Strict regex `^[a-zA-Z0-9._:-]{1,64}$` disallowing dash prefixes (`-`) prevents shell flag injection.
4. **Shell Sanitization**: Control characters are stripped and single quotes are escaped for POSIX shell execution before passing text to `input text`.
5. **Token Authentication**: Optional cryptographically secure random session token (`--auth` / `--token`) prevents unauthorized local processes from interacting with the bridge.
