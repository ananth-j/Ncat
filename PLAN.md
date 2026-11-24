# Logoi Performance Improvement Plan

> Analysis based on `logcat_controller.dart`, `log_table_view.dart`, `log_row.dart`,
> `logcat_page.dart`, `log_entry.dart`, `noise_filter.dart`, and the bridge/adb layer.

---

## Current Architecture Strengths (Don't Break These)

| Already done | Where |
|---|---|
| `ValueNotifier<List<LogEntry>> visibleNotifier` — only the list rebuilds on batches | `logcat_controller.dart:53` |
| `itemExtent: 23.0` fixed row height — Flutter skips layout for off-screen items | `log_table_view.dart:353` |
| `_LogRowStyles` / `Expando` style cache — zero `TextStyle.copyWith` allocs per row | `log_row.dart:90` |
| `RepaintBoundary` per row via `addRepaintBoundaries: true` | `log_table_view.dart:355` |
| Hover state lifted to `ValueNotifier` — only 2 rows rebuild on mouse move | `log_table_view.dart:72` |
| Incremental filter (Phase 2.2) — only new batch lines are tested, not the whole list | `logcat_controller.dart:325` |
| Background throttle (Phase 2.4) — no UI rebuild when window is backgrounded | `logcat_controller.dart:319` |
| `adb track-devices` push stream — zero polling CPU overhead | `adb_tracker.dart:64` |
| `StringPool` intern for tag/pkg/level strings | `log_entry.dart:6` |

---

## Identified Issues & Improvement Plan

### 🔴 P0 — High Impact / Low Effort

#### 1. `_matchesFilter` calls `pkgController.text.trim()` on every entry, every batch

```dart
// logcat_controller.dart:483 — called once per LogEntry on every batch
final isNoise = NoiseFilter.isNoise(
  e,
  appPid: _appPid,
  packageFilter: pkgController.text.trim(), // ← allocation + trim per row
);
```

**Fix:** Cache `pkgController.text.trim()` alongside the other filter cache fields in
`_updateFilterCache()`. Store it as `String _cachedPkg = ''` and pass the cached value.
Currently called on tens of thousands of invocations per second during heavy streaming.

---

#### 2. `LogEntry.rank` is a computed getter — recalculated on every `_matchesFilter` call

```dart
// log_entry.dart:40
int get rank => switch (level) { ... }; // recomputed every call
```

**Fix:** Make `rank` a `final int` field computed once in the constructor (or in `fromJson`).
The switch has 6 arms and fires per entry, per batch.

---

#### 3. `NoiseFilter.isNoise` calls `entry.tag.toLowerCase().trim()` on every invocation

```dart
// noise_filter.dart:167
final lowerTag = entry.tag.toLowerCase().trim(); // new String per call
```

**Fix:** Pre-compute `lowerTag` as a field on `LogEntry` (e.g. `final String tagLower`) in
`fromJson`. This eliminates one allocation per entry per filter evaluation, which at 8 000
visible rows × batch rate is significant GC pressure.

---

### 🟠 P1 — High Impact / Medium Effort

#### 4. `_HoverIsolatedList` rebuilds the entire `ListView.builder` closure on every hover event

```dart
// log_table_view.dart:346-376
return ValueListenableBuilder<int?>(
  valueListenable: hoveredSeq,
  builder: (context, hovered, _) {
    return ListView.builder(   // ← entire list re-created on hover
      ...
      itemBuilder: (context, i) {
        return LogRow(hoveredSeq: hovered, ...); // passes hovered to ALL rows
      },
    );
  },
);
```

Flutter's `ListView.builder` is lazy, so off-screen rows are not rebuilt — but **all visible
rows** do rebuild because `hovered` is threaded as a constructor arg to every `LogRow`. Since
`LogRow` is `StatelessWidget`, Flutter must call `build()` on each visible row just to decide
if the color changed.

**Fix A (Incremental):** Wrap `ColoredBox` + `Opacity` inside each `LogRow` in its own
`ValueListenableBuilder<int?>` that only checks `seq == hoveredSeq`. The `ListView.builder`
itself stays outside the `ValueListenableBuilder`.

**Fix B (Best):** Keep one `ValueNotifier<int?> hoveredSeq` in the state. Have each row
subscribe to it individually using `AnimatedBuilder`/`ListenableBuilder` scoped only to the
row's background color widget — not the whole row. This way hover flips exactly 2 tiny
`ColoredBox` rebuilds, touching zero other widgets.

---

#### 5. `notifyListeners()` is called twice on every batch (once per batch + once from `visibleNotifier`)

```dart
// logcat_controller.dart:375-376
visibleNotifier.value = List<LogEntry>.unmodifiable(_visible);
notifyListeners(); // triggers TopFilterBar, DeviceTabBar, LeftToolbar, StatusBar, LogTableView
```

The `ListenableBuilder` wrappers in `logcat_page.dart` around `TopFilterBar`,
`DeviceTabBar`, `LeftVerticalToolbar` and `LogcatStatusBar` all subscribe to `_controller`
(the full `ChangeNotifier`). Every incoming log batch rebuilds all four of them even though
their displayed data (device list, filter settings, connection status) hasn't changed.

**Fix:** Introduce fine-grained `ValueNotifier`s:
- `ValueNotifier<String> connectionNotifier` → drive `LogcatStatusBar` + connection dot
- `ValueNotifier<int> countNotifier` → drive line counts in `LogcatStatusBar`
- Keep `notifyListeners()` only for actual filter/device/settings changes

This means `LogcatStatusBar` rebuilds only when counts or connection change, not on every batch.

---

#### 6. `_recompute()` creates a new unmodifiable list wrapper on every call

```dart
// logcat_controller.dart:545
visibleNotifier.value = List<LogEntry>.unmodifiable(_visible);
```

This wraps `_visible` in a new `UnmodifiableListView` on every filter change. For 8 000
entries this is a 8 000-pointer copy just to get immutability.

**Fix:** Use `UnmodifiableListView<LogEntry>(_visible)` from `dart:collection` which wraps
without copying (it is a view), or expose `_visible` as `List.unmodifiable` only at the
getter level and pass the reference directly to `visibleNotifier`.

> `List.unmodifiable()` **copies** the list. `UnmodifiableListView()` from `dart:collection`
> is a **zero-copy view**. Use the latter.

---

#### 7. `Tooltip` on every package cell, even when text is not truncated

```dart
// log_row.dart:310-320
child: Tooltip(
  message: appPkg,
  child: Text(appPkg, maxLines: 1, overflow: TextOverflow.ellipsis),
),
```

`Tooltip` adds a `MouseRegion` + overlay listener to every visible row that shows a package
column. At 300+ visible rows this is hundreds of extra `MouseRegion` nodes in the gesture arena.

**Fix:** Conditionally show `Tooltip` only when `appPkg.length > N` (e.g. 18 chars), or use
a custom hover widget that lazily measures whether text overflows before attaching the tooltip overlay.

---

### 🟡 P2 — Medium Impact / Medium Effort

#### 8. The `_visible` trim loop on excess uses a linear scan

```dart
// logcat_controller.dart:348-355
var trimCount = 0;
while (trimCount < _visible.length && _visible[trimCount].seq < minSeq) {
  trimCount++;
}
if (trimCount > 0) _visible.removeRange(0, trimCount);
```

**Fix:** Use binary search (`lowerBound` from `package:collection`) on the sorted `seq`
field to find `trimCount` in O(log n) instead of O(n).

---

#### 9. `NoiseFilter._noisePrefixes` is a `List` — prefix check is O(prefixes × tag_length)

```dart
// noise_filter.dart:136-143
static final List<String> _noisePrefixes = ['wifi', 'audio', 'bt_', ...];
for (final prefix in _noisePrefixes) {
  if (lowerTag.startsWith(prefix)) return true;
}
```

**Fix:** Convert to a single compiled `RegExp` anchored at start:
`RegExp(r'^(wifi|audio|bt_|surfaceflinger|gnss|hwcomposer)')`. Compiled once, executed
in O(tag_length).

---

#### 10. `_matchesLevelTerm` calls `value.toUpperCase()` on every invocation

```dart
// logcat_controller.dart:515
final rank = switch (value.toUpperCase()) { ... }; // new String per call
```

**Fix:** Pre-uppercase `value` once in `LogQueryTerm` construction (store `_upperValue`
alongside `_lowerValue`).

---

#### 11. `setSearch` with `immediate: true` runs `_recompute()` synchronously on the UI thread

For 8 000+ lines, `_recompute()` can take several milliseconds and jank the frame if called
from `setFilterTag` or `applyPreset`.

**Fix:** When `_lines.length > 5000`, always defer to a microtask even on "immediate" calls.

---

### 🟢 P3 — Low Hanging Fruit / Polish

#### 12. `exportLogs` builds a `StringBuffer` on the main isolate

For large exports (8 000 lines × long messages), `exportLogs()` is synchronous and blocks
the UI thread until the buffer is assembled.

**Fix:** Move the `StringBuffer` loop into a `compute()` call (Dart isolate), passing the
`_visible` snapshot and column config as a simple data bundle.

---

#### 13. `_onDeviceChanged` calls `notifyListeners()` unconditionally

```dart
// logcat_controller.dart:39-41
void _onDeviceChanged() {
  notifyListeners(); // fires for every device list change, even no-op updates
}
```

**Fix:** Compare old vs new device list; skip `notifyListeners()` if the list is
structurally equal.

---

#### 14. `LogcatStatusBar` calls `devices.firstWhere(...)` on every build

```dart
// status_bar.dart:72-76
devices.firstWhere(
  (d) => d.serial == activeDevice,
  orElse: () => DeviceInfo(serial: activeDevice!),
).label,
```

This is an O(n) scan on every status bar rebuild.

**Fix:** Pass the resolved `DeviceInfo` (or just its label string) as a parameter from the
parent — the parent already has access to the full device list once.

---

## Priority Roadmap

```
🔴 P0  →  🟠 P1  →  🟡 P2  →  🟢 P3
```

| Phase | Items | Theme |
|---|---|---|
| P0 | 1, 2, 3 | Cache hot-path allocations (one-liners) |
| P1 | 4, 5, 6, 7 | Narrow widget rebuild scope |
| P2 | 8, 9, 10, 11 | Algorithmic improvements |
| P3 | 12, 13, 14 | Isolate offload & housekeeping |

---

## Effort vs Impact Matrix

| # | Issue | Impact | Effort | Priority |
|---|---|---|---|---|
| 1 | Cache `pkgController.text` in filter cache | 🔴 High | 🟢 Trivial | P0 |
| 2 | `rank` as `final int` field on `LogEntry` | 🔴 High | 🟢 Trivial | P0 |
| 3 | `tagLower` as `final String` field on `LogEntry` | 🟠 Medium | 🟢 Trivial | P0 |
| 4 | Per-row hover subscription (scoped `ColoredBox`) | 🟠 Medium | 🟡 Medium | P1 |
| 5 | Fine-grained `ValueNotifier`s for counts/connection | 🔴 High | 🟡 Medium | P1 |
| 6 | `UnmodifiableListView` zero-copy wrap | 🟠 Medium | 🟢 Trivial | P1 |
| 7 | Conditional `Tooltip` on package cell | 🟡 Low | 🟢 Trivial | P1 |
| 8 | Binary search trim (`lowerBound`) | 🟡 Low | 🟡 Medium | P2 |
| 9 | Regex prefix check in `NoiseFilter` | 🟡 Low | 🟡 Medium | P2 |
| 10 | Pre-uppercase query term value | 🟡 Low | 🟢 Trivial | P2 |
| 11 | Defer `_recompute()` for large lists | 🟡 Low | 🟡 Medium | P2 |
| 12 | `compute()` isolate for export | 🟡 Low | 🟡 Medium | P3 |
| 13 | Guard no-op `notifyListeners` in `_onDeviceChanged` | 🟡 Low | 🟢 Trivial | P3 |
| 14 | Pre-resolve device label in status bar | 🟡 Low | 🟢 Trivial | P3 |

---

> **Start with P0 items first** — items 1–3 are 3 one-line changes that together eliminate
> the highest-frequency allocation hotspots in the filter hot path, with zero architectural risk.
