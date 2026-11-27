import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'log_entry.dart';
import 'noise_filter.dart';

const _kLogTabsKey = 'ThruWire.log_tabs';
const _kActiveLogTabKey = 'ThruWire.active_log_tab';

/// Independent per-tab state for an Android Studio-style Logcat tab.
///
/// Multiple [LogTabState] instances can target the same device serial while
/// maintaining independent search queries, package filters, severity levels,
/// noise modes, pause snapshots, clear offsets, and scroll positions.
class LogTabState {
  LogTabState({
    required this.id,
    required this.title,
    this.isCustomTitle = false,
    this.deviceSerial,
    this.search = '',
    this.packageFilter = '',
    this.minLevel = 'V',
    this.useRegex = false,
    this.noiseMode = NoiseFilterMode.reduce,
    this.autoScroll = true,
    this.paused = false,
    this.wrap = true,
    this.clearedAfterSeq,
    this.scrollOffset = 0.0,
  });

  final String id;
  String title;
  bool isCustomTitle;

  /// Target device serial for this tab, or `null` to follow auto-selection.
  String? deviceSerial;

  String search;
  String packageFilter;
  String minLevel;
  bool useRegex;
  NoiseFilterMode noiseMode;
  bool autoScroll;
  bool paused;
  bool wrap;

  /// Sequence boundary for per-tab clearing without wiping sibling tabs.
  int? clearedAfterSeq;

  /// Frozen line snapshot captured when this tab is paused independently.
  List<LogEntry>? pausedBufferSnapshot;

  /// Saved scroll offset when [autoScroll] is off.
  double scrollOffset;

  /// Human-readable tab label: custom title if renamed, otherwise derived
  /// from the active package/query or fallback tab title.
  String get displayTitle {
    if (isCustomTitle && title.trim().isNotEmpty) {
      return title.trim();
    }
    final pkg = packageFilter.trim();
    if (pkg.isNotEmpty) {
      return pkg;
    }
    final q = search.trim();
    if (q.isNotEmpty) {
      return q;
    }
    return title;
  }

  LogTabState copyWith({
    String? id,
    String? title,
    bool? isCustomTitle,
    String? deviceSerial,
    bool clearDeviceSerial = false,
    String? search,
    String? packageFilter,
    String? minLevel,
    bool? useRegex,
    NoiseFilterMode? noiseMode,
    bool? autoScroll,
    bool? paused,
    bool? wrap,
  }) {
    return LogTabState(
      id: id ?? this.id,
      title: title ?? this.title,
      isCustomTitle: isCustomTitle ?? this.isCustomTitle,
      deviceSerial:
          clearDeviceSerial ? null : (deviceSerial ?? this.deviceSerial),
      search: search ?? this.search,
      packageFilter: packageFilter ?? this.packageFilter,
      minLevel: minLevel ?? this.minLevel,
      useRegex: useRegex ?? this.useRegex,
      noiseMode: noiseMode ?? this.noiseMode,
      autoScroll: autoScroll ?? this.autoScroll,
      paused: paused ?? this.paused,
      wrap: wrap ?? this.wrap,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'isCustomTitle': isCustomTitle,
    'deviceSerial': deviceSerial,
    'search': search,
    'packageFilter': packageFilter,
    'minLevel': minLevel,
    'useRegex': useRegex,
    'noiseMode': noiseMode.name,
    'wrap': wrap,
  };

  factory LogTabState.fromJson(Map<String, dynamic> j) {
    final modeName = j['noiseMode'] as String?;
    final mode = NoiseFilterMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => NoiseFilterMode.reduce,
    );
    return LogTabState(
      id: j['id'] as String? ?? 'tab_1',
      title: j['title'] as String? ?? 'Logcat 1',
      isCustomTitle: j['isCustomTitle'] as bool? ?? false,
      deviceSerial: j['deviceSerial'] as String?,
      search: j['search'] as String? ?? '',
      packageFilter: j['packageFilter'] as String? ?? '',
      minLevel: j['minLevel'] as String? ?? 'V',
      useRegex: j['useRegex'] as bool? ?? false,
      noiseMode: mode,
      wrap: j['wrap'] as bool? ?? true,
    );
  }
}

/// Persists open log tabs and the active tab ID.
Future<void> saveLogTabs(List<LogTabState> tabs, String activeTabId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kLogTabsKey,
      jsonEncode(tabs.map((t) => t.toJson()).toList()),
    );
    await prefs.setString(_kActiveLogTabKey, activeTabId);
  } catch (_) {}
}

/// Loads persisted log tabs and active tab ID, if any.
Future<({List<LogTabState> tabs, String? activeTabId})> loadLogTabs() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLogTabsKey);
    final activeId = prefs.getString(_kActiveLogTabKey);
    if (raw == null || raw.isEmpty) {
      return (tabs: <LogTabState>[], activeTabId: activeId);
    }
    final decoded = jsonDecode(raw) as List;
    final tabs =
        decoded
            .whereType<Map<String, dynamic>>()
            .map(LogTabState.fromJson)
            .toList();
    return (tabs: tabs, activeTabId: activeId);
  } catch (_) {
    return (tabs: <LogTabState>[], activeTabId: null);
  }
}
