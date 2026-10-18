# Wcat Implementation Plan: Open-Source Architecture & Advanced Features

> **Target Goal**: Transform `wcat` from a single-file logcat viewer into a modular, production-grade Android companion tool ready for open-source publication, featuring **screen mirroring**, **screen recording**, **screenshot capture**, and **multi-device mirroring**.

---

## Architecture Overview

```
                      ┌────────────────────────────────────────┐
                      │              Flutter UI                │
                      │  (ListenableBuilder / ChangeNotifiers) │
                      └───────┬────────────────────────┬───────┘
                              │                        │
                 Control & Logs (WS)            Video / Media (HTTP)
                              │                        │
                              ▼                        ▼
                      ┌────────────────────────────────────────┐
                      │          Dart Bridge Server            │
                      │  ┌──────────────────────────────────┐  │
                      │  │         Session Manager          │  │
                      │  │   DeviceSession    DeviceSession │  │
                      │  │   (Pixel 7 Pro)    (Galaxy S24)  │  │
                      │  └────────┬─────────────────┬───────┘  │
                      └───────────┼─────────────────┼──────────┘
                                  │                 │
                                  ▼                 ▼
                          adb logcat / shell   screencap / screenrecord
```

---

## Phase 1: Modularization & Architecture Refactor (Current Baseline)
*Objective: Deconstruct the 2,218-line `lib/main.dart` into feature-first modules with zero regressions.*

- [x] **1.1 Establish Core Protocol & Shared Models**
  - Create `lib/protocol/messages.dart` with sealed classes (`BridgeMessage`, `LogBatchMessage`, `StatusMessage`).
  - Create `lib/protocol/commands.dart` (`FilterCommand`, `DeviceCommand`, `ClearCommand`).
  - Verify JSON serialization matches existing bridge server payloads.

- [x] **1.2 Extract Core & Design System**
  - Move color palettes and styling to `lib/core/theme/palette.dart` and `theme_pref.dart`.
  - Move cross-platform export helpers to `lib/core/utils/export/`.
  - Extract constants (buffer caps, flush intervals) to `lib/core/constants/`.

- [x] **1.3 Extract Device Feature**
  - Create `lib/features/devices/models/device_info.dart`.
  - Create `lib/features/devices/device_controller.dart` to manage device discovery, active serial, and connection state.
  - Extract `DeviceSelector` dropdown widget.

- [x] **1.4 Extract Logcat Feature**
  - Move `LogEntry` to `lib/features/logcat/models/log_entry.dart`.
  - Create `lib/features/logcat/logcat_controller.dart` managing ring buffer, filtering, search, and pause/resume.
  - Extract `LogTableView`, `LogFilterBar`, `ColumnConfigDialog`, and `PresetBar` into `lib/features/logcat/widgets/`.

- [x] **1.5 Streamline `main.dart`**
  - Reduce `main.dart` to app initialization, dependency wiring, and high-level scaffold.
  - Run `flutter analyze` and `flutter test` to ensure zero breakages.

---

## Phase 2: Screenshot & Screen Recording Pipeline
*Objective: Add instant screen capture and hardware-encoded video recording with zero external host codecs.*

- [ ] **2.1 Bridge Capture Endpoints**
  - Add `GET /api/screenshot?serial=<serial>`: Executes `adb -s <serial> exec-out screencap -p` and streams PNG bytes.
  - Add `POST /api/record/start?serial=<serial>`: Spawns `adb -s <serial> shell screenrecord --bit-rate 6000000 /sdcard/wcat_rec.mp4`.
  - Add `POST /api/record/stop?serial=<serial>`: Terminates recording process, pulls file to host machine via `adb pull`, and cleans up device temp file.

- [ ] **2.2 Frontend Capture Service & Controller**
  - Implement `CaptureService` in `lib/features/mirroring/capture_service.dart`.
  - Add screenshot trigger with instant preview modal and one-click save / copy to clipboard.
  - Add recording timer badge (e.g. `● REC 00:14`) and download notification.

- [ ] **2.3 Top Toolbar Integration**
  - Add quick-action icons: 📸 Screenshot (`Ctrl+Shift+S`) and ⏺ Record (`Ctrl+Shift+R`).

---

## Phase 3: Screen Mirroring (Single Device)
*Objective: Provide real-time screen streaming with low latency and optional touch/mouse input.*

- [ ] **3.1 Bridge Video Stream Channel**
  - Implement MJPEG streamer endpoint `GET /api/stream?serial=<serial>` (spawning frame pump) or binary WebSocket frame channel.
  - Keep video bandwidth completely isolated from the logcat WebSocket to prevent lag spikes.

- [ ] **3.2 UI Screen Mirror Component**
  - Implement `ScreenMirrorView` widget with dynamic aspect ratio fitting (phone, tablet, foldable).
  - Implement responsive side-by-side split view: Logcat on left, Screen Mirror on right.
  - Add toggle button to collapse/expand screen mirror pane.

- [ ] **3.3 Interactive Input Forwarding (Optional / Progressive)**
  - Map mouse clicks on mirror widget to `adb shell input tap <x> <y>`.
  - Map keyboard text inputs to `adb shell input text <escaped_string>`.
  - Add navigation soft-keys (Back, Home, App Switcher, Power, Volume).

---

## Phase 4: Multi-Screen & Multi-Device Matrix
*Objective: Allow monitoring and interacting with multiple connected emulators/devices simultaneously.*

- [ ] **4.1 Bridge Session Manager (`DeviceSession`)**
  - Refactor bridge server from single-device global state to a `Map<String, DeviceSession>`.
  - Allow concurrent logcat streaming and screen recording across multiple serials.

- [ ] **4.2 Multi-Device UI Layouts**
  - **Tabs Mode**: Switch between devices with independent filter states and log buffers.
  - **Grid / Matrix Mode**: View 2 to 4 device screens in a customizable grid with unified or per-device log toggles.
  - Add "Mirror All" / "Screenshot All" bulk actions.

---

## Phase 5: Open-Source Polish & Community Readiness
*Objective: Meet top-tier open-source standards for documentation, contribution ease, and CI/CD.*

- [ ] **5.1 Documentation Suite**
  - `README.md`: Modernized with animated demo GIFs, feature highlights, and quickstart commands.
  - `docs/ARCHITECTURE.md`: High-level system diagram and module breakdown.
  - `docs/PROTOCOL.md`: Full WebSocket and REST specification for third-party client integrations.
  - `CONTRIBUTING.md`: Development environment setup, linting rules, and PR checklist.

- [ ] **5.2 Automated CI/CD Workflows**
  - GitHub Actions workflow for:
    - Code formatting (`dart format --output=none --set-exit-if-changed .`)
    - Static analysis (`flutter analyze --fatal-infos`)
    - Unit tests (`flutter test`)
    - Release builds for Windows, macOS, Linux, and Web.

---

## Comprehensive Test Suite Plan (All Layers)
*Objective: Achieve 95%+ deterministic test coverage across state, protocol, parsing, and UI without requiring physical Android hardware in CI.*

- [x] **T.1 Protocol & Serialization Tests (`test/protocol_test.dart`)**
  - [x] Decode `HistoryMessage`, `LogBatchMessage`, `ClearMessage`, `StatusMessage`.
  - [x] Encode `FilterCommand`, `ClearCommand`, `RestartCommand`, `DeviceCommand`.

- [x] **T.2 Controller & Buffer State Tests (`test/features/logcat/logcat_controller_test.dart`)**
  - [x] Buffer cap enforcement (drops oldest entries beyond 8,000 capacity).
  - [x] Pause/resume filtering (skips lines when paused).
  - [x] Multi-criteria filtering (minLevel severity ranking, search substring, regex, package).
  - [x] Presets lifecycle (save, delete, reapply preset).
  - [x] Log export formatting (time, PID-TID, package, level, tag, message).

- [x] **T.3 Bridge & ADB Parsing Tests (`test/bridge/bridge_parser_test.dart`)**
  - [x] Standard logcat line parsing (PID, TID, level, tag, msg).
  - [x] Broken or non-standard format fallback handling.
  - [x] `adb devices -l` output parsing (extract model, serial, unauthorized, offline states).

- [x] **T.4 Component & Widget Tests (`test/features/logcat/widgets_test.dart`)**
  - [x] `TopFilterBar`: Search input, level change, regex button, device selector.
  - [x] `LeftVerticalToolbar`: Action button taps, pause toggle icon, theme switcher.
  - [x] `LogcatStatusBar`: Connection indicator dot, PID, device label, line counts.
  - [x] `LogTableView` & `LogRow`: Context menu actions, copy full line, filter by tag/package.
  - [x] `ColumnConfigDialog` & `PresetsDialog`: Checkboxes, presets, input fields.

- [x] **T.5 Performance & Scale Benchmarks (`test/features/logcat/performance_test.dart`)**
  - [x] **Burst Intake**: Ingests 50,000 log lines in < 350ms with strictly bounded ring buffer (8,000 max lines).
  - [x] **Sub-Frame Search**: Substring text filtering across 8,000 lines completes in < 35ms (60fps ready).
  - [x] **Regex Evaluation**: Complex compiled regex query over 8,000 lines completes in < 50ms.
  - [x] **Severity Ranking**: Level filter over 8,000 lines completes in < 20ms.
  - [x] **Memory Stability**: Continuous stream of 100,000 lines maintains zero memory drift.
  - [x] **Bulk Export**: Formats 8,000 full log lines into `.log` string in < 45ms.

