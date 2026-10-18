# Contributing to Wcat

Thank you for your interest in contributing to Wcat! We welcome bug reports, feature requests, documentation improvements, and pull requests.

---

## 1. Code of Conduct

All contributors and participants are expected to adhere to our [Code of Conduct](CODE_OF_CONDUCT.md). Please treat all members of the community with respect and kindness.

---

## 2. Prerequisites & Setup

To build and contribute to Wcat, you need:
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.7 or higher, 3.24+ recommended)
- [Dart SDK](https://dart.dev/get-started) (included with Flutter)
- Android platform-tools (`adb`) installed on your `PATH` or configured via `ANDROID_HOME` or `ADB`.
- Optional: `scrcpy` in your `PATH` for hardware-accelerated mirroring tests.

### Clone and initialize:
```bash
git clone https://github.com/ananth-j/wcat.git
cd wcat
flutter pub get
```

---

## 3. Architecture & Guidelines

Before making significant changes, please review:
- [Architecture Guide](docs/ARCHITECTURE.md)
- [Communication Protocol](docs/PROTOCOL.md)
- [Security Policy](SECURITY.md)

### Core Rules:
1. **Dumb Pipe Host**: Never introduce host-side video transcoding (e.g., ffmpeg or OpenCV). Keep host CPU below 2% at idle and below 5% during screen mirroring.
2. **Device Isolation**: All state on the bridge and frontend must be isolated by device serial (`DeviceSession`). Never assume a single global device.
3. **Loopback Only**: Network services must only bind to `127.0.0.1`.
4. **Clean Code & Zero Warnings**: Code must produce 0 analyzer issues (`flutter analyze --fatal-infos`).
5. **Cross-Platform Compatibility**: Do not import `dart:io` in files that compile to Web. Use the conditional import pattern (`lib/bridge/bridge_manager_io.dart` vs `lib/bridge/bridge_manager_stub.dart`).

---

## 4. Development Workflow

1. **Fork & Branch**: Create a feature branch off `main`:
   ```bash
   git checkout -b feature/my-cool-feature
   ```

2. **Run Tests**:
   Ensure all existing tests pass:
   ```bash
   flutter test
   ```

3. **Verify Formatting & Static Analysis**:
   ```bash
   dart format --output=none --set-exit-if-changed .
   flutter analyze --fatal-infos
   ```

4. **Add Unit Tests**:
   - Write tests for new logic, controllers, and bridge handlers in `test/`.
   - Use `FakeProcessRunner` for bridge process testing to keep tests fast and deterministic without requiring physical devices.

---

## 5. Pull Request Checklist

Before opening a pull request, ensure:
- [ ] `flutter test` passes 100%.
- [ ] `flutter analyze --fatal-infos` reports 0 issues.
- [ ] `dart format` has been applied to all modified files.
- [ ] New functionality includes unit tests.
- [ ] Documentation has been updated (if protocol, endpoints, or architecture changed).
- [ ] Commit messages are clear and descriptive.
