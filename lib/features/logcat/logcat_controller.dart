import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/constants.dart';
import '../../protocol/commands.dart';
import '../../protocol/messages.dart';
import '../../src/bridge_manager.dart';
import '../../src/column_config.dart';
import '../../src/export.dart';
import '../../src/filter_preset.dart';
import '../devices/device_controller.dart';
import '../devices/models/device_info.dart';
import 'models/log_entry.dart';
import 'models/log_query.dart';
import 'models/noise_filter.dart';

// Re-export device and noise models for backward compatibility
export '../devices/device_controller.dart'
    show DeviceViewMode, DeviceTabState, DeviceController;
export 'models/noise_filter.dart' show NoiseFilterMode, NoiseFilter;

/// Central state controller for logcat streaming, filtering, presets, and export.
class LogcatController extends ChangeNotifier with WidgetsBindingObserver {
  LogcatController({
    int maxLines = kMaxLines,
    DeviceController? deviceController,
  })  : _maxLines = maxLines,
        _deviceController = deviceController ?? DeviceController() {
    _deviceController.addListener(_onDeviceChanged);
  }

  final int _maxLines;
  final DeviceController _deviceController;

  void _onDeviceChanged() {
    notifyListeners();
  }

  final List<LogEntry> _lines = [];
  final List<LogEntry> _visible = [];

  /// A dedicated [ValueNotifier] for the visible list.
  ///
  /// UI components that only need to react to new log rows (e.g. the log
  /// table) should subscribe to this notifier rather than the full
  /// [ChangeNotifier]. That way incoming log batches do not force a rebuild
  /// of every widget that listens to the controller — only the list view
  /// itself is rebuilt.
  final ValueNotifier<List<LogEntry>> visibleNotifier =
      ValueNotifier<List<LogEntry>>([]);

  final ScrollController scrollController = ScrollController();
  final TextEditingController searchController = TextEditingController();
  final TextEditingController pkgController = TextEditingController();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;
  Timer? _searchDebounce;

  String _connection = 'connecting';
  String _serverStatus = '';
  int? _appPid;

  DeviceTabState _getOrCreateTab(String serial) =>
      _deviceController.getOrCreateTab(serial);

  List<FilterPreset> _presets = const [];

  String _search = '';
  String _minLevel = 'V';
  bool _paused = false;
  bool _wrap = true;
  bool _autoScroll = true;
  bool _useRegex = false;
  NoiseFilterMode _noiseMode = NoiseFilterMode.reduce;
  int _hiddenNoiseCount = 0;

  // Background mode tracking (Phase 2.4)
  bool _isAppActive = true;
  bool _needsUiSync = false;

  // Filter cache (Phase 2.2)
  int _cachedMinRank = 0;
  LogQuery _cachedQuery = LogQuery('');

  LogColumnConfig _columns = const LogColumnConfig();

  // Getters
  int get maxLines => _maxLines;
  List<LogEntry> get lines => _lines;
  List<LogEntry> get visible => _visible;
  String get connection => _connection;
  String get serverStatus => _serverStatus;
  int? get appPid => _appPid;
  List<DeviceInfo> get devices => _deviceController.devices;
  String? get activeDevice => _deviceController.activeDevice;
  String? get pickedDevice => _deviceController.pickedDevice;
  DeviceViewMode get viewMode => _deviceController.viewMode;
  Map<String, DeviceTabState> get tabStates => _deviceController.tabStates;
  DeviceController get deviceController => _deviceController;
  List<FilterPreset> get presets => _presets;
  String get search => _search;
  String get minLevel => _minLevel;
  bool get paused => _paused;
  bool get wrap => _wrap;
  bool get autoScroll => _autoScroll;
  bool get useRegex => _useRegex;
  NoiseFilterMode get noiseMode => _noiseMode;
  bool get reduceNoise => _noiseMode == NoiseFilterMode.reduce;
  int get hiddenNoiseCount => _hiddenNoiseCount;
  LogColumnConfig get columns => _columns;

  void init() {
    WidgetsBinding.instance.addObserver(this);
    scrollController.addListener(_onScroll);
    _updateFilterCache();

    loadColumnConfig().then((c) {
      _columns = c;
      notifyListeners();
    });
    loadFilterPresets().then((p) {
      _presets = p;
      notifyListeners();
    });
    _initBridgeAndConnect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Phase 2.4: When window is hidden/minimized/unfocused, buffer without rebuilding UI
    final active = state == AppLifecycleState.resumed;
    if (_isAppActive != active) {
      _isAppActive = active;
      if (_isAppActive && _needsUiSync) {
        _needsUiSync = false;
        _recompute();
      }
    }
  }

  void _onScroll() {
    if (!scrollController.hasClients) return;
    final max = scrollController.position.maxScrollExtent;
    final current = scrollController.offset;
    final atBottom = max <= 0 || current >= (max - 50);
    if (atBottom && !_autoScroll) {
      _autoScroll = true;
      notifyListeners();
    } else if (!atBottom && _autoScroll) {
      _autoScroll = false;
      notifyListeners();
    }
  }

  /// Fixed row height used by [ListView.builder] when wrap is off.
  /// Must stay in sync with the [itemExtent] value in [LogTableView._logList].
  static const double _rowExtent = 23.0;

  /// Jumps the scroll position to the bottom of the list.
  ///
  /// When [wrap] is off the list uses a fixed [itemExtent], so we can
  /// calculate the exact target offset from the item count without waiting
  /// for a layout frame — eliminating the one-frame stutter caused by using
  /// [maxScrollExtent] inside a [WidgetsBinding.addPostFrameCallback].
  ///
  /// When [wrap] is on row heights vary, so we fall back to [maxScrollExtent]
  /// (still in a post-frame callback, but that case is rare while streaming).
  void scrollToBottom() {
    if (!_isAppActive || !scrollController.hasClients) return;

    if (!_wrap && _visible.isNotEmpty) {
      // Fixed-height fast path: compute offset from item count directly.
      // This fires synchronously in the same frame — no layout round-trip needed.
      final viewportHeight = scrollController.position.viewportDimension;
      final totalHeight = _visible.length * _rowExtent;
      final target = (totalHeight - viewportHeight).clamp(
        0.0,
        double.infinity,
      );
      scrollController.jumpTo(target);
    } else {
      // Variable-height fallback: wait for layout to know maxScrollExtent.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_autoScroll && scrollController.hasClients) {
          scrollController.jumpTo(scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  void scrollToEnd() {
    // Jump first — before notifyListeners() triggers a rebuild.
    // This way the scroll position is already at the bottom when Flutter
    // lays out the new frame, so the user never sees the intermediate state.
    scrollToBottom();
    _autoScroll = true;
    notifyListeners();
  }

  void scrollToTop() {
    _autoScroll = false;
    notifyListeners();
    if (scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
  }

  Future<void> _initBridgeAndConnect() async {
    await ensureBridgeRunning();
    _connect();
  }

  Uri get _serverUri {
    final host = Uri.base.host.isEmpty ? '127.0.0.1' : Uri.base.host;
    return Uri.parse('ws://$host:8080/ws');
  }

  Future<void> _connect() async {
    _reconnect?.cancel();
    _connection = 'connecting';
    notifyListeners();

    final ch = WebSocketChannel.connect(_serverUri);
    try {
      await ch.ready;
    } catch (_) {
      _scheduleReconnect();
      return;
    }

    _channel = ch;
    _sub = ch.stream.listen(
      _onRawMessage,
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
    );
    _connection = 'live';
    notifyListeners();
  }

  void _scheduleReconnect() {
    _connection = 'offline';
    _sub?.cancel();
    _channel = null;
    notifyListeners();
    _reconnect = Timer(const Duration(seconds: 2), _connect);
  }

  void sendCommand(BridgeCommand cmd) {
    _channel?.sink.add(jsonEncode(cmd.toJson()));
  }

  void _onRawMessage(dynamic raw) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    handleMessage(BridgeMessage.fromJson(data));
  }

  @visibleForTesting
  void handleMessage(BridgeMessage message) {
    switch (message) {
      case HistoryMessage(:final lines, :final serial):
        final targetSerial = serial ?? activeDevice;
        if (targetSerial != null) {
          final tab = _getOrCreateTab(targetSerial);
          tab.lines
            ..clear()
            ..addAll(lines);
        }
        if (targetSerial == null || targetSerial == activeDevice) {
          _lines
            ..clear()
            ..addAll(lines);
          _recompute();
          if (_autoScroll) {
            scrollToBottom();
          }
        }
        break;

      case LogBatchMessage(:final lines, :final serial):
        if (_paused) return;
        final targetSerial = serial ?? activeDevice;
        if (targetSerial != null) {
          final tab = _getOrCreateTab(targetSerial);
          tab.lines.addAll(lines);
          final excess = tab.lines.length - _maxLines;
          if (excess > 0) {
            tab.lines.removeRange(0, excess);
          }
        }

        // If batch is targeted to a background tab, buffer it without rebuilding UI
        if (targetSerial != null &&
            activeDevice != null &&
            targetSerial != activeDevice) {
          return;
        }

        _lines.addAll(lines);
        final maxCapacity = _autoScroll ? _maxLines : _maxLines * 2;
        final excess = _lines.length - maxCapacity;
        if (excess > 0) {
          _lines.removeRange(0, excess);
        }

        // Phase 2.4: If window is backgrounded/minimized, keep buffering but skip UI rebuilds
        if (!_isAppActive) {
          _needsUiSync = true;
          return;
        }

        // Phase 2.2: Incremental filtering - test ONLY newly arrived lines
        final passing = lines.where(_matchesFilter).toList(growable: false);
        if (_noiseMode == NoiseFilterMode.reduce) {
          final currentPkg = pkgController.text.trim();
          for (final l in lines) {
            if (!_matchesFilter(l) &&
                NoiseFilter.isNoise(
                  l,
                  appPid: _appPid,
                  packageFilter: currentPkg,
                )) {
              _hiddenNoiseCount++;
            }
          }
          if (excess > 0 && _hiddenNoiseCount > _lines.length) {
            _hiddenNoiseCount = (_lines.length - _visible.length).clamp(
              0,
              _lines.length,
            );
          }
        }
        if (passing.isNotEmpty) {
          if (excess > 0 && _visible.isNotEmpty) {
            final minSeq = _lines.first.seq;
            var trimCount = 0;
            while (trimCount < _visible.length &&
                _visible[trimCount].seq < minSeq) {
              trimCount++;
            }
            if (trimCount > 0) {
              _visible.removeRange(0, trimCount);
            }
            _visible.addAll(passing);
          } else {
            _visible.addAll(passing);
          }
        } else if (excess > 0 && _visible.isNotEmpty) {
          final minSeq = _lines.first.seq;
          var trimCount = 0;
          while (trimCount < _visible.length &&
              _visible[trimCount].seq < minSeq) {
            trimCount++;
          }
          if (trimCount > 0) {
            _visible.removeRange(0, trimCount);
          }
        }

        // Phase 2.1: Exactly one notifyListeners per incoming batch
        // Also publish the updated visible list to visibleNotifier so the
        // log table can rebuild independently of the full controller listeners.
        visibleNotifier.value = List<LogEntry>.unmodifiable(_visible);
        notifyListeners();
        if (_autoScroll) {
          scrollToBottom();
        }
        break;

      case ClearMessage(:final serial):
        final targetSerial = serial ?? activeDevice;
        if (targetSerial != null) {
          _deviceController.tabStates[targetSerial]?.lines.clear();
        }
        if (targetSerial == null || targetSerial == activeDevice) {
          _lines.clear();
          _hiddenNoiseCount = 0;
          _recompute();
        }
        break;

      case StatusMessage(
        :final status,
        :final pid,
        :final devices,
        :final activeDevice,
      ):
        _serverStatus = status;
        _appPid = pid;
        _deviceController.updateDevices(
          devices,
          serverActiveDevice: activeDevice,
        );
        notifyListeners();
        break;

      case HandshakeMessage():
        break;

      case UnknownMessage():
        break;
    }
  }

  void selectDeviceTab(String serial) {
    if (activeDevice == serial) return;

    // 1. Save current active tab filter state
    final current = activeDevice;
    if (current != null) {
      final currentTab = _getOrCreateTab(current);
      currentTab.search = _search;
      currentTab.minLevel = _minLevel;
      currentTab.packageFilter = pkgController.text.trim();
      currentTab.useRegex = _useRegex;
      currentTab.autoScroll = _autoScroll;
      currentTab.paused = _paused;
      currentTab.noiseMode = _noiseMode;
    }

    // 2. Switch to target device tab
    _deviceController.setActiveDevice(serial);
    final tab = _getOrCreateTab(serial);

    _search = tab.search;
    searchController.text = tab.search;
    pkgController.text = tab.packageFilter;
    _minLevel = tab.minLevel;
    _useRegex = tab.useRegex;
    _autoScroll = tab.autoScroll;
    _paused = tab.paused;
    _noiseMode = tab.noiseMode;

    _updateFilterCache();
    _lines
      ..clear()
      ..addAll(tab.lines);

    _recompute();
    sendCommand(DeviceCommand(serial));
    notifyListeners();
  }

  void setViewMode(DeviceViewMode mode) {
    _deviceController.setViewMode(mode);
  }

  void toggleViewMode() {
    _deviceController.toggleViewMode();
  }

  void _updateFilterCache() {
    _cachedMinRank = switch (_minLevel) {
      'V' => 0,
      'D' => 1,
      'I' => 2,
      'W' => 3,
      'E' => 4,
      'F' || 'S' => 5,
      _ => kLevels.indexOf(_minLevel).clamp(0, kLevels.length - 1),
    };
    _cachedQuery = LogQuery(_search, useRegex: _useRegex);
  }

  bool _matchesFilter(LogEntry e) {
    if (e.rank < _cachedMinRank) return false;

    final isNoise = NoiseFilter.isNoise(
      e,
      appPid: _appPid,
      packageFilter: pkgController.text.trim(),
    );

    if (!_cachedQuery.hasNoiseTerm) {
      if (_noiseMode == NoiseFilterMode.reduce && isNoise) {
        return false;
      } else if (_noiseMode == NoiseFilterMode.onlyNoise && !isNoise) {
        return false;
      }
    }

    for (final term in _cachedQuery.terms) {
      final field = term.field;
      final matched = switch (field) {
        'tag' => term.matches(e.tag),
        'message' => term.matches(e.msg),
        'package' => term.matches(
          e.pkg ?? (_appPid == e.pid ? pkgController.text.trim() : ''),
        ),
        'process' => term.matches(
          e.pkg ?? (_appPid == e.pid ? pkgController.text.trim() : '${e.pid}'),
        ),
        'level' => _matchesLevelTerm(e, term.value, term.negated),
        'is' => term.matches(isNoise ? 'noise' : 'clean'),
        _ => term.matches('${e.tag} ${e.msg}'),
      };
      if (!matched) return false;
    }
    return true;
  }

  bool _matchesLevelTerm(LogEntry entry, String value, bool negated) {
    final rank = switch (value.toUpperCase()) {
      'V' || 'VERBOSE' => 0,
      'D' || 'DEBUG' => 1,
      'I' || 'INFO' => 2,
      'W' || 'WARN' || 'WARNING' => 3,
      'E' || 'ERROR' => 4,
      'F' || 'S' || 'ASSERT' || 'FATAL' => 5,
      _ => -1,
    };
    final matched = rank >= 0 && entry.rank >= rank;
    return negated ? !matched : matched;
  }

  void _recompute() {
    _updateFilterCache();
    _visible.clear();
    int hidden = 0;
    final isReduced = _noiseMode == NoiseFilterMode.reduce;
    final currentPkg = pkgController.text.trim();

    for (final e in _lines) {
      if (_matchesFilter(e)) {
        _visible.add(e);
      } else if (isReduced &&
          NoiseFilter.isNoise(e, appPid: _appPid, packageFilter: currentPkg)) {
        hidden++;
      }
    }
    _hiddenNoiseCount = hidden;
    // Publish a new list reference so visibleNotifier listeners rebuild.
    visibleNotifier.value = List<LogEntry>.unmodifiable(_visible);
    notifyListeners();
  }

  // User Actions
  void setNoiseMode(NoiseFilterMode mode) {
    if (_noiseMode == mode) return;
    _noiseMode = mode;
    _recompute();
  }

  void toggleReduceNoise() {
    setNoiseMode(
      _noiseMode == NoiseFilterMode.reduce
          ? NoiseFilterMode.showAll
          : NoiseFilterMode.reduce,
    );
  }

  void setSearch(String v, {bool immediate = true}) {
    _search = v;
    if (immediate) {
      _searchDebounce?.cancel();
      _recompute();
    } else {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 150), _recompute);
    }
  }

  void setMinLevel(String v) {
    _minLevel = v;
    _recompute();
  }

  void toggleRegex() {
    _useRegex = !_useRegex;
    _recompute();
  }

  void togglePaused() {
    _paused = !_paused;
    notifyListeners();
  }

  void toggleWrap() {
    _wrap = !_wrap;
    notifyListeners();
  }

  void applyPackage() {
    final pkg = pkgController.text.trim();
    sendCommand(FilterCommand(pkg.isEmpty ? null : pkg));
  }

  void setFilterPackage(String pkg) {
    pkgController.text = pkg;
    applyPackage();
  }

  void setFilterTag(String tag) {
    searchController.text = tag;
    _search = tag;
    _recompute();
  }

  void clearLogs() {
    sendCommand(const ClearCommand());
  }

  void restartAdb() {
    sendCommand(const RestartCommand());
  }

  void applyDevice(String? serial) {
    _deviceController.applyDevice(serial);
    sendCommand(DeviceCommand(serial));
  }

  void updateColumns(LogColumnConfig next) {
    _columns = next;
    saveColumnConfig(next);
    notifyListeners();
  }

  Future<void> savePreset(String name) async {
    final preset = FilterPreset(
      name: name,
      package: pkgController.text.trim(),
      search: searchController.text,
      minLevel: _minLevel,
      useRegex: _useRegex,
    );
    final next = [..._presets.where((p) => p.name != name), preset];
    _presets = next;
    notifyListeners();
    await saveFilterPresets(next);
  }

  Future<void> deletePreset(FilterPreset preset) async {
    final next = _presets.where((p) => p.name != preset.name).toList();
    _presets = next;
    notifyListeners();
    await saveFilterPresets(next);
  }

  void applyPreset(FilterPreset preset) {
    pkgController.text = preset.package;
    searchController.text = preset.search;
    _minLevel = preset.minLevel;
    _useRegex = preset.useRegex;
    _search = preset.search;
    _recompute();
    applyPackage();
  }

  Future<String> exportLogs() async {
    final buf = StringBuffer();
    for (final e in _visible) {
      final parts = <String>[];
      if (_columns.showTime) parts.add(e.time);
      if (_columns.showPidTid) parts.add('${e.pid}-${e.tid}');
      if (_columns.showPackage) {
        final pkg =
            e.pkg ??
            (_appPid != null && e.pid == _appPid
                ? pkgController.text.trim()
                : null);
        if (pkg != null && pkg.isNotEmpty) parts.add(pkg);
      }
      if (_columns.showLevel && _columns.showTag) {
        parts.add('${e.level}/${e.tag}:');
      } else {
        if (_columns.showLevel) parts.add('[${e.level}]');
        if (_columns.showTag) parts.add('${e.tag}:');
      }
      parts.add(e.msg);
      buf.writeln(parts.join(' '));
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final filename = 'logcat_$stamp.log';

    return exportLog(buf.toString(), filename);
  }

  void copyLogEntry(LogEntry e) {
    final parts = <String>[];
    if (_columns.showTime) parts.add(e.time);
    if (_columns.showPidTid) parts.add('${e.pid}-${e.tid}');
    if (_columns.showPackage) {
      final pkg =
          e.pkg ??
          (_appPid != null && e.pid == _appPid
              ? pkgController.text.trim()
              : null);
      if (pkg != null && pkg.isNotEmpty) parts.add(pkg);
    }
    if (_columns.showLevel && _columns.showTag) {
      parts.add('${e.level}/${e.tag}:');
    } else {
      if (_columns.showLevel) parts.add('[${e.level}]');
      if (_columns.showTag) parts.add('${e.tag}:');
    }
    parts.add(e.msg);

    Clipboard.setData(ClipboardData(text: parts.join(' ')));
  }

  @override
  void dispose() {
    _deviceController.removeListener(_onDeviceChanged);
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _reconnect?.cancel();
    _searchDebounce?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
    searchController.dispose();
    pkgController.dispose();
    visibleNotifier.dispose();
    stopBridge();
    super.dispose();
  }
}
