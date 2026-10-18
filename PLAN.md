# Wcat Implementation Plan v2: MVP, Performance-First, Low Host Footprint

> **Target Goal**: Evolve `wcat` from a modular logcat viewer into a lightweight Android companion tool with **screenshot**, **screen recording**, **screen mirroring**, and **multi-device** support, while keeping CPU and RAM usage on the host PC as low as possible.

## Guiding Principles (MVP)

1. **Performance first, host footprint second, features third.** Every feature must pass the resource budget below before it ships.
2. **The bridge is a dumb pipe.** No host-side transcoding. Let the Android device's hardware encoder do the work, and let the host's hardware decoder (or an external tool) do the decoding.
3. **Everything on demand.** Mirror streams, recording and device polling run only while something is actually using them.
4. **Security is deferred for the MVP**, with one free exception: bind the bridge to `127.0.0.1` only. Add a "not for shared networks" note to the README. Full hardening (token auth, Origin checks, serial validation, input escaping) is tracked in Phase 6.
5. **Correctness items that are not negotiable**: valid MP4 on recording stop, no orphaned `adb` / `screenrecord` processes.

### Resource Budget (targets to verify in DevTools / Task Manager)

| Scenario | Target |
|---|---|
| Idle, logcat connected, nothing streaming | Near-zero CPU, a few hundred MB RAM at most |
| Window minimized / unfocused | No UI rebuilds, buffering only |
| One mirrored device at 720p | Well under one CPU core |
| Mirror pane collapsed | Stream process killed, CPU returns to idle |

Always measure with **release or profile builds**, never debug.

---

## Architecture Overview

```
                      ┌────────────────────────────────────────┐
                      │              Flutter UI                │
                      │  (ListenableBuilder / ChangeNotifiers) │
                      └───────┬────────────────────────┬───────┘
                              │                        │
                 Control & Logs (WS)           Video (binary WS / hw decode)
                              │                        │
                              ▼                        ▼
                      ┌────────────────────────────────────────┐
                      │   Dart Bridge Server (127.0.0.1 only)  │
                      │  ┌──────────────────────────────────┐  │
                      │  │   Session Manager (Map<serial,   │  │
                      │  │          DeviceSession>)         │  │
                      │  └────────┬─────────────────┬───────┘  │
                      │     ProcessRunner (fakeable in tests)  │
                      └───────────┼─────────────────┼──────────┘
                                  ▼                 ▼
                       adb logcat / track-devices / exec-out screenrecord
```

---

## Phase 1: Modularization (Done)

- [x] 1.1 Core protocol and shared models
- [x] 1.2 Core and design system extraction
- [x] 1.3 Device feature
- [x] 1.4 Logcat feature
- [x] 1.5 Streamlined `main.dart`
- [x] Test suite T.1 to T.5 (protocol, controller, bridge parser, widgets, performance)

---

## Phase 1.5: Foundations for Everything Else
*Objective: Do the cheap refactors now so Phases 2 to 4 don't need rewrites.*

- [x] **1.5.1 `ProcessRunner` abstraction**
  - Interface wrapping `Process.start` / `Process.run` so the bridge can be tested against a fake `adb` with no hardware.
  - Always pass argument lists, never shell strings.

- [x] **1.5.2 `DeviceSession` manager (moved up from old Phase 4.1)**
  - Replace single-device global state with `Map<String, DeviceSession>`.
  - Each session owns its logcat process, optional stream process and optional recording process, plus a `dispose()` that kills them all.
  - Kill orphaned `screenrecord` processes and temp files on bridge start and on device disconnect.

- [x] **1.5.3 Protocol versioning**
  - Add `protocolVersion` handshake and a `serial` field on all messages for later multiplexing.
  - Draft `docs/PROTOCOL.md` now (finalize in Phase 5).

- [x] **1.5.4 Replace device polling with `adb track-devices`**
  - Push-based device list updates, zero cost while idle.

- [x] **1.5.5 Bind bridge to `127.0.0.1`** (`InternetAddress.loopbackIPv4`).

---

## Phase 2: Logcat Efficiency Pass
*Objective: Make the already-working core cheap on CPU and RAM before adding video.*

- [x] **2.1 Batched updates**: flush parsed lines every 100 to 250 ms; one `notifyListeners` per batch.
- [x] **2.2 Incremental filtering**: test only newly arrived lines against the active filter; recompile regex only when the query changes.
- [x] **2.3 Virtualized list**: `ListView.builder` with fixed `itemExtent`.
- [x] **2.4 Background mode**: when the window is minimized or unfocused, keep buffering but skip UI rebuilds.
- [x] **2.5 Memory hygiene**: lightweight `LogEntry`, reuse strings for repeated tags and packages, make buffer cap configurable (default 8,000).

---

## Phase 3: Screenshot and Screen Recording
*Objective: Instant capture and valid, hardware-encoded recordings with minimal host cost.*

- [x] **3.1 Bridge capture endpoints**
  - `GET /api/screenshot?serial=` runs `adb -s <serial> exec-out screencap -p` and streams PNG bytes.
  - `POST /api/record/start?serial=` spawns `adb -s <serial> shell screenrecord --bit-rate 6000000 /sdcard/wcat_<serial>_<timestamp>.mp4` (unique filename per session).
  - `POST /api/record/stop?serial=`:
    1. Send **SIGINT on the device** (`pkill -2 screenrecord` or `kill -2 <pid>`), **not** by killing the host `adb` process.
    2. Wait for the process to exit so the MP4 is finalized.
    3. `adb pull`, then delete the device temp file.
  - Handle the **3-minute `screenrecord` limit**: either auto-segment and restart, or show a warning in the REC badge.
  - Serve the finished file over HTTP so web or remote clients can download it.

- [x] **3.2 Frontend capture service**
  - `CaptureService` in `lib/features/mirroring/capture_service.dart`.
  - Screenshot preview modal with save and copy-to-clipboard (needs a clipboard package such as `super_clipboard`).
  - Recording timer badge (`● REC 00:14`) and download notification.

- [x] **3.3 Toolbar integration**
  - Screenshot and Record quick actions. Make shortcuts configurable (defaults like `Ctrl+Shift+S/R` collide with browser shortcuts on Web).

---

## Phase 4: Screen Mirroring (Single Device, Low Footprint)
*Objective: Real-time mirroring that doesn't burn the host CPU.*

- [x] **4.1 Pick the mirroring path (in this order)**
  1. **MVP quick win: "Launch scrcpy" button.** Lowest host cost (hardware decode), mature, no embedded view yet.
  2. **Embedded H.264 passthrough:** bridge pipes `adb exec-out screenrecord --output-format=h264 --size 720x1600 --bit-rate 3000000 -` bytes straight to the UI. UI decodes with hardware decode (`media_kit` on desktop). **No ffmpeg transcoding on the host.**
  3. **Fallback preview mode:** `screencap` loop at about 2 to 5 fps for devices or setups where H.264 isn't available.
  - Note: `screenrecord` has a 3-minute limit, so restart the stream seamlessly.

- [x] **4.2 On-demand lifecycle**
  - Stream starts when the mirror pane opens; the `adb` process is killed when the pane collapses or the window is minimized.

- [x] **4.3 Quality controls**
  - Resolution and bitrate presets (for example 480p, 720p). UI refresh capped around 30 fps.

- [x] **4.4 `ScreenMirrorView` widget**
  - Aspect-ratio fitting, split view (logcat left, mirror right), collapse/expand toggle.
  - Update via `ValueNotifier` and `RawImage` (or the video widget) inside its own `RepaintBoundary`. No `setState` per frame; keep only the latest frame; dispose old `ui.Image` frames immediately.

- [x] **4.5 Input forwarding (optional)**
  - Use **one persistent `adb shell` session** and write `input tap` / `input swipe` commands to stdin (avoids ~100 to 300 ms process spawn per tap).
  - Soft-keys: Back, Home, App Switcher, Power, Volume.
  - Later: use scrcpy's control channel for smooth drags and text.

---

## Phase 5: Multi-Device Matrix

- [x] **5.1 Tabs mode** with independent filter state and log buffers per device.
- [x] **5.2 Grid mode (2 to 4 devices)**
  - Hard cap on concurrently live streams (for example 2 live, others show a static screenshot).
  - Lower fps and resolution per tile; pause hidden tiles.
- [x] **5.3 Bulk actions**: "Screenshot All" and "Mirror All" (respecting the stream cap).

---

## Phase 6: Hardening and Open-Source Release

- [x] **6.1 Security hardening (deferred from MVP)**
  - Random per-session token, Origin check on WS upgrade, validate `serial` against known devices, proper escaping for `input text`.
  - Add `SECURITY.md`.

- [x] **6.2 Documentation**
  - `README.md` (demo GIFs, quickstart, MVP / security note), `docs/ARCHITECTURE.md`, finalized `docs/PROTOCOL.md`, `CONTRIBUTING.md`.
  - Document distribution: how Web users run the bridge, whether desktop embeds it, and adb discovery (`ANDROID_HOME`, `PATH`, manual setting). Don't bundle platform-tools without checking its license terms.

- [x] **6.3 Repo essentials**: `LICENSE` (plus dependency license audit, especially if bundling scrcpy-server), `CHANGELOG.md`, `CODE_OF_CONDUCT.md`, issue and PR templates, versioning policy.

- [x] **6.4 CI/CD (can start earlier; format/analyze/test jobs are cheap)**
  - `dart format --output=none --set-exit-if-changed .`
  - `flutter analyze --fatal-infos`
  - `flutter test --coverage` with a coverage threshold check
  - Release builds for Windows, macOS, Linux, Web (note macOS signing/notarization and Windows SmartScreen in docs).

---

## Test Suite Plan

### Existing (Done)
- [x] **T.1** Protocol and serialization
- [x] **T.2** Controller and buffer state
- [x] **T.3** Bridge and ADB parsing
- [x] **T.4** Component and widget tests
- [x] **T.5** Performance and scale benchmarks

### Adjustments
- [x] **T.5a** Make timing thresholds generous (for example 3x to 5x local numbers) or tag them with `@Tags(['perf'])` and run separately, since hard limits like `< 35ms` are flaky on shared CI runners.
- [x] **T.5b** Replace "zero memory drift" with a verifiable assertion: buffer length stays at or below the cap after a 100,000-line stream.
- [x] **T.5c** Add an "incremental filter" benchmark: appending a batch to an active filter only evaluates new lines.

### New
- [x] **T.6 Bridge process tests** using the fake `ProcessRunner`:
  - Recording stop sends SIGINT then pulls; no orphaned processes after stop, disconnect or bridge shutdown.
  - `track-devices` output parsing and reconnect behavior.
  - Stream lifecycle: starts on subscribe, killed on unsubscribe.
- [x] **T.7 Session manager tests**: multiple serials, independent buffers, `dispose()` cleans up everything.
- [x] **T.8 Protocol versioning tests**: handshake accepted and rejected cases.
- [x] **T.9 Manual resource checklist** (release build): idle, minimized, 1-device mirror, mirror collapsed. Record CPU and RAM against the budget table.

---

## Suggested Build Order

1. Phase 1.5 foundations (`ProcessRunner`, `DeviceSession`, protocol version, `track-devices`, loopback bind)
2. Phase 2 logcat efficiency pass
3. Phase 3 screenshot, then recording (SIGINT and segmenting)
4. Phase 4: scrcpy launch button, then embedded H.264 passthrough
5. Phase 5 multi-device
6. Phase 6 hardening and open-source release (CI jobs can start early)

## Risks to Watch

| Risk | Mitigation |
|---|---|
| Host transcoding eats CPU | Passthrough H.264 and hardware decode only |
| Unplayable recordings | SIGINT on device, wait for exit, then pull |
| Orphaned `adb` processes | `DeviceSession.dispose()`, startup cleanup, tests |
| Multi-stream resource blowup | Stream cap, per-tile limits, pause hidden tiles |
| Flaky perf tests in CI | Generous thresholds or separate tag |
| Security debt forgotten | Phase 6.1 is tracked and README carries an MVP note |