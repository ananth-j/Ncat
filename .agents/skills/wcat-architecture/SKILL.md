---
name: wcat-architecture
description: >-
  Architectural guidelines, layer rules, and design patterns for the wcat open-source
  project. Use when refactoring, adding new features (screen mirroring, recording,
  screenshots, multi-screen matrix), or implementing bridge communication.
---

# wcat Architecture Guide

`wcat` is a fast, lightweight Android companion and logcat streaming tool built with a **Flutter frontend** and a **Dart bridge server**. This guide defines the architectural standards required to keep the project clean, modular, and maintainable as an open-source tool.

---

## 1. Core Principles

1. **Pragmatic Layering (No Enterprise Overkill)**:
   - Use standard Flutter state management (`ChangeNotifier` / `ValueNotifier` with `ListenableBuilder`).
   - Keep business logic in controllers/view models; keep views lean and declarative.
   - Do not create superfluous Clean Architecture abstractions (no empty UseCases or 5-layer DTOs).

2. **Decoupled Bridge & Frontend**:
   - The Flutter UI communicates with the Dart Bridge via a strongly-typed protocol (WebSocket for control/logs, HTTP endpoints for binary streams/captures).
   - The bridge remains standalone and runnable without Flutter (`dart run bin/server.dart`).

3. **Per-Device Session Isolation**:
   - All state on the bridge and UI must be keyed by device serial (`DeviceSession`). Never assume a single global device.

4. **Stream Separation**:
   - **Logs & Control**: Low-frequency / batched JSON over WebSocket (`ws://<host>:<port>/ws`).
   - **Screen Video**: High-frequency binary/MJPEG over dedicated HTTP/TCP stream (`GET /stream?serial=XYZ`) to prevent logcat backpressure.

---

## 2. Directory Structure Standard

Follow a **feature-first** organization:

```text
lib/
├── main.dart                      # App entry point, top-level dependency wiring
│
├── core/                          # Cross-cutting utilities & design system
│   ├── constants/                 # Ports, default limits, keys
│   ├── theme/                     # App palette, typography, dark/light modes
│   └── utils/                     # Formatters, cross-platform export helpers
│
├── protocol/                      # Shared communication contract (Client & Bridge)
│   ├── messages.dart              # Typed event models (LogMessage, DeviceStatus)
│   └── commands.dart              # Typed commands (FilterCmd, DeviceCmd, RecordCmd)
│
├── features/
│   ├── devices/                   # Device discovery & selection
│   │   ├── models/device_info.dart
│   │   ├── device_controller.dart # Manages active devices & sessions
│   │   └── widgets/device_selector.dart
│   │
│   ├── logcat/                    # Core log viewer & filtering
│   │   ├── models/log_entry.dart
│   │   ├── logcat_controller.dart # Ring buffer, search, level filtering
│   │   └── widgets/
│   │       ├── log_table.dart
│   │       ├── log_filter_bar.dart
│   │       └── column_config_dialog.dart
│   │
│   └── mirroring/                 # Screen mirror, capture & recording
│       ├── mirror_controller.dart # Video stream listener & aspect ratio
│       ├── capture_service.dart   # Screenshot & screenrecord operations
│       └── widgets/
│           ├── screen_mirror_view.dart  # Canvas / Texture for live video
│           ├── capture_toolbar.dart     # Screenshot & Record buttons
│           └── multi_screen_grid.dart   # Multi-device split/grid layout
│
└── bridge/                        # Bridge server & process management
    ├── bridge_manager.dart        # Auto-launches server on desktop (IO vs Stub)
    ├── server/
    │   ├── bridge_server.dart     # HTTP & WebSocket routing
    │   ├── device_session.dart    # Isolated state per connected device
    │   └── runners/
    │       ├── adb_runner.dart    # Low-level process runner & path finder
    │       ├── logcat_runner.dart # adb logcat process & regex parser
    │       └── screen_runner.dart # adb screencap / scrcpy-server wrapper
```

---

## 3. Communication Protocol

All messages exchanged between the Flutter client and the Dart bridge must be modeled using Dart 3 sealed classes:

```dart
// protocol/messages.dart
sealed class BridgeMessage {
  const BridgeMessage();
  factory BridgeMessage.fromJson(Map<String, dynamic> json) { ... }
}

class StatusMessage extends BridgeMessage {
  final String status;
  final List<DeviceInfo> devices;
  final String? activeSerial;
  const StatusMessage({required this.status, required this.devices, this.activeSerial});
}

class LogBatchMessage extends BridgeMessage {
  final List<LogEntry> lines;
  const LogBatchMessage(this.lines);
}
```

```dart
// protocol/commands.dart
sealed class BridgeCommand {
  const BridgeCommand();
  Map<String, dynamic> toJson();
}

class FilterCommand extends BridgeCommand {
  final String? package;
  const FilterCommand(this.package);
  @override
  Map<String, dynamic> toJson() => {'cmd': 'filter', 'package': package};
}
```

---

## 4. Multi-Device & Screen Mirroring Architecture

### A. The DeviceSession Model
On the bridge, wrap every connected device in a `DeviceSession`:
```dart
class DeviceSession {
  final String serial;
  final AdbRunner adb;
  LogcatRunner? logcat;
  ScreenRunner? screen;

  DeviceSession({required this.serial, required this.adb});

  void startLogcat({String? packageFilter}) { ... }
  void stopLogcat() { ... }
  Stream<Uint8List> startScreenStream() { ... }
}
```

### B. Screenshot Implementation
- Command: `adb -s <serial> exec-out screencap -p`
- Transport: Bridge serves `GET /api/screenshot?serial=<serial>` returning `image/png`.
- Frontend: Downloads or saves directly to disk using `export_io.dart` / `export_web.dart`.

### C. Screen Recording Implementation
- Native Android recording requires no desktop video encoding:
  1. Bridge triggers `adb -s <serial> shell screenrecord --bit-rate 4000000 /sdcard/wcat_temp.mp4`.
  2. When recording is stopped, bridge runs `adb -s <serial> pull /sdcard/wcat_temp.mp4 <local_path>`.
  3. Bridge cleans up on device: `adb -s <serial> shell rm /sdcard/wcat_temp.mp4`.

### D. Live Mirroring
- **Phase 2**: Stream MJPEG frames over an HTTP stream (`GET /api/stream?serial=<serial>`).
- **Phase 3 (High-performance)**: Deploy `scrcpy-server.jar` to `/data/local/tmp/` via ADB and stream H.264 frames to Flutter desktop texture / WebRTC.

---

## 5. Guidelines for Contributors

1. **Keep `main.dart` minimal**: No UI widgets or business logic in `main.dart`.
2. **Never commit hardcoded ADB paths**: Always resolve through `findAdbPath()` or user configuration.
3. **Handle disconnected devices gracefully**: Devices can unplug at any millisecond. All ADB runners must handle process termination without crashing the bridge server.
4. **Maintain cross-platform support**: Do not introduce OS-specific packages that break macOS, Linux, Windows, or Web builds. Use conditional imports (`*_io.dart` / `*_stub.dart` / `*_web.dart`).
