import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'log_entry.dart';
import 'log_query.dart';
import 'noise_filter.dart';

const _kLogTabsKey = 'ThruWire.log_tabs';
const _kActiveLogTabKey = 'ThruWire.active_log_tab';

/// Independent per-tab state, controllers, buffers, and filter cache for an
/// Android Studio-style Logcat tab.
///
/// Multiple [LogTabState] instances can target the same device serial while
/// maintaining independent search queries, package filters, severity levels,
/// noise modes, pause snapshots, clear offsets, toolbars, and scroll positions.
class LogTabState {
  LogTabState({
    required this.id,
    required this.title,
    this.isCustomTitle = false,
    this.deviceSerial,
    String search = '',
    String packageFilter = '',
    this.minLevel = 'V',
    this.useRegex = false,
    this.noiseMode = NoiseFilterMode.reduce,
    this.autoScroll = true,
    this.paused = false,
    this.wrap = true,
    this.clearedAfterSeq,
    this.scrollOffset = 0.0,
  }) : _search = search,
       _packageFilter = packageFilter,
       searchController = TextEditingController(text: search),
       pkgController = TextEditingController(text: packageFilter),
       cachedQuery = LogQuery(search, useRegex: useRegex);

  final String id;
  String title;
  bool isCustomTitle;

  /// Target device serial for this tab, or `null` to follow auto-selection.
  String? deviceSerial;

  String _search;
  String _packageFilter;

  String get search => _search;
  set search(String v) {
    _search = v;
    if (searchController.text != v) {
      searchController.text = v;
    }
  }

  String get packageFilter => _packageFilter;
  set packageFilter(String v) {
    _packageFilter = v;
    if (pkgController.text != v) {
      pkgController.text = v;
    }
  }

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

  // Per-tab UI controllers & reactive notifiers
  final TextEditingController searchController;
  final TextEditingController pkgController;
  final ScrollController scrollController = ScrollController();

  final List<LogEntry> lines = [];
  final List<LogEntry> visible = [];

  final ValueNotifier<List<LogEntry>> visibleNotifier =
      ValueNotifier<List<LogEntry>>([]);
  final ValueNotifier<LogStats> statsNotifier = ValueNotifier<LogStats>((
    total: 0,
    visible: 0,
    hiddenNoise: 0,
  ));

  int hiddenNoiseCount = 0;
  int cachedMinRank = 0;
  LogQuery cachedQuery;

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  void publishVisibleAndStats() {
    if (_isDisposed) return;
    visibleNotifier.value = UnmodifiableListView<LogEntry>(visible);
    statsNotifier.value = (
      total: lines.length,
      visible: visible.length,
      hiddenNoise: hiddenNoiseCount,
    );
  }

  /// Human-readable tab label: custom title if renamed, otherwise derived
  /// from the active package/query or fallback tab title.
  String get displayTitle {
    if (isCustomTitle && title.trim().isNotEmpty) {
      return title.trim();
    }
    final pkg = _packageFilter.trim();
    if (pkg.isNotEmpty) {
      return pkg;
    }
    final q = _search.trim();
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
      search: search ?? _search,
      packageFilter: packageFilter ?? _packageFilter,
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
    'search': _search,
    'packageFilter': _packageFilter,
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

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    searchController.dispose();
    pkgController.dispose();
    scrollController.dispose();
    visibleNotifier.dispose();
    statsNotifier.dispose();
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
