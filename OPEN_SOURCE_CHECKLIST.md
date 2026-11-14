# ThruWire — Open-Source Launch Checklist

> [!IMPORTANT]
> The project has been fully renamed from `wcat` → **ThruWire** / `ThruWire`. All Dart imports, platform manifests, CMake configs, Windows resources, iOS plist, Web manifest, docs, and test files have been updated. `flutter analyze` passes with **0 issues**.

---

## ✅ Phase 1 — Rename (DONE)

- [x] `pubspec.yaml` — package name set to `ThruWire`
- [x] All Dart `package:wcat/` imports → `package:ThruWire/`
- [x] All `wcat`/`Wcat` references in `lib/`, `bin/`, `test/` → `ThruWire`/`ThruWire`
- [x] `windows/CMakeLists.txt` — `BINARY_NAME` = `ThruWire`, project = `ThruWire`
- [x] `linux/CMakeLists.txt` — `BINARY_NAME` = `ThruWire`, `APPLICATION_ID` = `com.ThruWire.app`
- [x] `windows/runner/main.cpp` — window title = `ThruWire`
- [x] `windows/runner/flutter_window.cpp` — method channel = `ThruWire/scrcpy_embed`
- [x] `windows/runner/Runner.rc` — `ProductName`, `InternalName`, `OriginalFilename` → ThruWire
- [x] `android/app/src/main/AndroidManifest.xml` — `android:label` = `ThruWire`
- [x] `ios/Runner/Info.plist` — `CFBundleDisplayName` = `ThruWire`, `CFBundleName` = `ThruWire`
- [x] `web/index.html` — `<title>` and meta tags = `ThruWire`
- [x] `web/manifest.json` — `name`, `short_name`, `description` = `ThruWire`
- [x] `lib/main.dart` — app `title: 'ThruWire'`
- [x] All markdown docs (`README.md`, `PLAN.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `docs/ARCHITECTURE.md`, `docs/PROTOCOL.md`) — `wcat`/`Wcat` → `ThruWire`/`ThruWire`
- [x] `.agents/skills/wcat-architecture/SKILL.md` updated
- [x] Scrcpy local tools path — `%LOCALAPPDATA%\ThruWire\tools\scrcpy`
- [x] `flutter pub get` — regenerated package config ✅
- [x] `flutter analyze` — **0 issues** ✅

---

## 🔲 Phase 2 — Android Package ID Rename (Manual)

> [!WARNING]
> This requires renaming Kotlin source directories and updating `build.gradle`. Flutter's rename tool or manual steps are needed.

- [ ] Rename Android package ID from `com.example.logoi` → `com.ThruWire.app`
  - [ ] `android/app/build.gradle` → update `applicationId "com.ThruWire.app"`
  - [ ] Rename directory: `android/app/src/main/kotlin/com/example/logoi/` → `com/ThruWire/app/`
  - [ ] Update `MainActivity.kt` package declaration → `package com.ThruWire.app`
- [ ] iOS Bundle ID: set `com.ThruWire.app` in `ios/Runner.xcodeproj` (requires Xcode or `agvtool`)
- [ ] macOS Bundle ID: same update in `macos/Runner.xcodeproj`

---

## 🔲 Phase 3 — GitHub Repository Setup

- [ ] **Create GitHub repo** named `ThruWire` (or `ThruWire`) under your account/org
- [ ] **Rename local folder** `E:\logoi` → `E:\ThruWire` (optional, cosmetic)
- [ ] Update the **CI badge URLs** in `README.md`:
  - Change `https://github.com/ananth-j/wcat/actions/...` → your new repo URL
- [ ] Add a **repo description** and **topics** (e.g. `android`, `adb`, `logcat`, `flutter`, `developer-tools`, `scrcpy`)
- [ ] Set repo **visibility** to Public
- [ ] Add a **social preview image** (repo banner/screenshot)

---

## 🔲 Phase 4 — License & Legal

- [ ] Verify `LICENSE` file — currently MIT ✅ (already present)
- [ ] Update the copyright year/name in `LICENSE` to match your real identity or org name
- [ ] Update copyright in `windows/runner/Runner.rc` (`LegalCopyright` field) — currently updated to `ThruWire Contributors`
- [ ] **Dependency license audit**:
  - `web_socket_channel` — BSD-3-Clause ✅
  - `shared_preferences` — BSD-3-Clause ✅
  - `web` — BSD-3-Clause ✅
  - `scrcpy` — Apache 2.0 (not bundled, discovered at runtime) ✅
  - `adb` — Google SDK license (not bundled, discovered at runtime) ✅
  - Confirm no GPL-incompatible dependency is bundled in the binary
- [ ] Add a `NOTICE` file if any dependency requires attribution

---

## ✅ Phase 5 — Documentation Polish (DONE)

- [x] **README.md**
  - [x] Replace placeholder CI badge URLs with real repo URLs
  - [x] Add a screenshot or animated GIF of the UI (`docs/screenshots/thruwire_ui_preview.png` & `.svg`)
  - [x] Add a "Download" / "Releases" section linking to GitHub Releases
  - [x] Update "Contributing" link to point to the new repo
- [x] **CHANGELOG.md** — Add `v1.0.0` entry with launch date and feature summary
- [x] **docs/PROTOCOL.md** — Verify all endpoint URLs and examples are accurate
- [x] **docs/ARCHITECTURE.md** — Verify diagrams and layer descriptions are current

---

## ✅ Phase 6 — CI/CD (GitHub Actions) (DONE)

> [!NOTE]
> Workflows updated for `ThruWire` across `.github/workflows/ci.yml` and `.github/workflows/release.yml`.

- [x] Verify or create `.github/workflows/ci.yml` with jobs:
  - [x] `dart format --output=none --set-exit-if-changed .`
  - [x] `flutter analyze --fatal-infos`
  - [x] `flutter test --coverage`
  - [x] Coverage verification & summary step (console & `$GITHUB_STEP_SUMMARY`)
- [x] Add **release build jobs** (`.github/workflows/release.yml`):
  - [x] `flutter build windows --release` (`thruwire-windows-x64.zip`)
  - [x] `flutter build linux --release` (`thruwire-linux-x64.tar.gz`)
  - [x] `flutter build macos --release` (`thruwire-macos.zip`)
  - [x] `flutter build web --release` (`thruwire-web.zip`)
- [x] Add **GitHub Release workflow** triggered on `v*` tag push (`softprops/action-gh-release@v2`)
- [x] Set up **Codecov** for coverage reporting (`codecov/codecov-action@v4`)

---

## 🔲 Phase 7 — Community Files & GitHub Settings

- [ ] Review and finalize `.github/ISSUE_TEMPLATE/bug_report.md` — updated ✅
- [ ] Review and finalize `.github/ISSUE_TEMPLATE/feature_request.md` — updated ✅
- [ ] Add a **Pull Request template**: `.github/PULL_REQUEST_TEMPLATE.md`
- [ ] Enable **GitHub Discussions** (for Q&A, feature ideas)
- [ ] Configure **Branch protection rules** on `main`:
  - Require PR reviews before merging
  - Require status checks (CI) to pass
- [ ] Add **GitHub labels** (bug, enhancement, good first issue, help wanted, etc.)
- [ ] (Optional) Set up a **GitHub Project board** for tracking issues

---

## 🔲 Phase 8 — First Release

- [ ] Run full test suite: `flutter test` (target: 86/86 passing)
- [ ] Do a **profile build** and verify resource budgets against README benchmarks
- [ ] Tag `v1.0.0` and push → triggers release workflow
- [ ] Upload release binaries to GitHub Releases
- [ ] Announce on relevant communities (r/androiddev, flutter Discord, Hacker News, etc.)

---

## 📋 Quick Reference — Key Files Changed

| File | What Changed |
|---|---|
| `pubspec.yaml` | `name: ThruWire` |
| `lib/main.dart` | `title: 'ThruWire'` |
| `windows/runner/main.cpp` | Window title `ThruWire` |
| `windows/runner/Runner.rc` | Product metadata → ThruWire |
| `windows/runner/flutter_window.cpp` | Channel `ThruWire/scrcpy_embed` |
| `windows/CMakeLists.txt` | `BINARY_NAME = ThruWire` |
| `linux/CMakeLists.txt` | `BINARY_NAME = ThruWire`, app ID |
| `android/AndroidManifest.xml` | `android:label = ThruWire` |
| `ios/Runner/Info.plist` | `CFBundleDisplayName = ThruWire` |
| `web/index.html` | `<title>ThruWire</title>` |
| `web/manifest.json` | `name: ThruWire` |
| All 17 test files | `package:ThruWire/` imports |
| All Dart sources | `wcat` → `ThruWire` |
| All markdown docs | `Wcat`/`wcat` → `ThruWire`/`ThruWire` |
| `scrcpy_resolver.dart` | Local path `ThruWire\tools\scrcpy` |
