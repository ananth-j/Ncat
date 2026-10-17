# wcat 🐱

A fast, filterable `adb logcat` viewer with a Flutter desktop/web UI and a
lightweight Dart bridge server. No Android Studio required — just `adb`, a
connected device or emulator, and Flutter.

```
Android device/emulator ──adb logcat──▶ bridge server ──WebSocket──▶ Flutter UI
```

## Features

- Live-tailing log view with color-coded severity levels (V/D/I/W/E/F)
- Filter by minimum severity, package name, or free-text search (tag or
  message), with an optional regex mode
- Pick which attached device to stream from, or let it auto-follow the first
  one adb reports
- Save named filter presets (package + search + level) and reapply them later
- Export the current (filtered) view to a `.log` file
- Pause/resume the stream, clear the buffer, or restart `adb logcat` from the UI
- Word wrap toggle, one-click copy of individual log lines
- Auto-reconnects to the bridge if it restarts or the connection drops
- Runs on macOS, Windows, Linux, and the web (Chrome) — same codebase, no
  platform-specific code

## Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.7+)
- Android [platform-tools](https://developer.android.com/tools/releases/platform-tools)
  (`adb`) available on your `PATH`, or set the `ADB` environment variable to
  its full path
- A connected Android device (USB debugging enabled) or a running emulator

## Getting started

1. Install dependencies:

   ```sh
   flutter pub get
   ```

2. Run the Flutter app:

   ```sh
   flutter run -d windows    # or macos / linux / chrome
   ```

   On desktop (Windows, macOS, Linux), the app **automatically starts the bridge in the background** and connects to your device immediately.

   *Note for Web or remote setups*: If running on Chrome or hosting remotely, start the bridge server in a separate terminal:
   ```sh
   dart run bin/server.dart
   ```

## Filtering to one app

Type a package name (e.g. `com.example.app`) into the package field and
press Enter. The bridge resolves its PID via `adb shell pidof`/`ps` and drops
every log line that isn't from that process before it ever reaches the
browser — so only lines from your app are shipped over the socket.

## Project structure

```
lib/main.dart     Flutter UI: log list, filters, toolbar, WebSocket client
bin/server.dart    Dart bridge: spawns `adb logcat`, parses + batches lines,
                    serves them to WebSocket clients (pure dart:io, no deps)
test/              Unit tests for log parsing/severity ranking
```

## Serving a static build alongside the bridge

For a single deployable artifact, build the web app and point the bridge at
the output directory — it'll serve the static files and the WebSocket from
the same port:

```sh
flutter build web
dart run bin/server.dart --web build/web
```

## Testing

```sh
flutter test
flutter analyze
```

## Platform notes

- **macOS**: the app is sandboxed; outbound WebSocket connections require the
  `com.apple.security.network.client` entitlement, already set in
  `macos/Runner/*.entitlements`.
- **Windows/Linux**: no additional configuration needed.
- Mobile (Android/iOS) scaffolding exists but isn't the primary target — this
  tool is meant to run on the machine that has `adb` and the device attached.

## Contributing

Issues and pull requests are welcome.

## License

MIT
