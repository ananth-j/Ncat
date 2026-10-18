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
import '../devices/models/device_info.dart';
import 'models/log_entry.dart';

/// View display modes for multi-device workflows.
enum DeviceViewMode { singleOrTabs, grid }

/// Isolated log buffer and filter state for a single connected device.
class DeviceTabState {
  DeviceTabState({required this.serial});

  final String serial;
  final List<LogEntry> lines = [];
  List<LogEntry> visible = [];
  String search = '';
  String minLevel = 'V';
  String packageFilter = '';
  bool useRegex = false;
  bool autoScroll = true;
  bool paused = false;
  int? appPid;
}

/// Central state controller for logcat streaming, filtering, presets, and export.
class LogcatController extends ChangeNotifier with WidgetsBindingObserver {
  LogcatController({int maxLines = kMaxLines}) : _maxLines = maxLines;

  final int _maxLines;
  final List<LogEntry> _lines = [];
  List<LogEntry> _visible = const [];

  final ScrollController scrollController = ScrollController();
  final TextEditingController searchController = TextEditingController();
  final TextEditingController pkgController = TextEditingController();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;

  String _connection = 'connecting';
  String _serverStatus = '';
  int? _appPid;

  List<DeviceInfo> _devices = const [];
  String? _activeDevice;
  String? _pickedDevice;

  DeviceViewMode _viewMode = DeviceViewMode.singleOrTabs;
  final Map<String, DeviceTabState> _tabStates = {};

  DeviceTabState _getOrCreateTab(String serial) {
    return _tabStates.putIfAbsent(serial, () => DeviceTabState(serial: serial));
  }

  List<FilterPreset> _presets = const [];

  String _search = '';
  String _minLevel = 'V';
  bool _paused = false;
  bool _wrap = true;
  bool _autoScroll = true;
  bool _useRegex = false;

  // Background mode tracking (Phase 2.4)
  bool _isAppActive = true;
  bool _needsUiSync = false;

  // Filter cache (Phase 2.2)
  int _cachedMinRank = 0;
  String _cachedQuery = '';
  String _cachedQueryLower = '';
  RegExp? _cachedRegex;
  bool _cachedUseRegex = false;

  LogColumnConfig _columns = const LogColumnConfig();

  // Getters
  int get maxLines => _maxLines;
  List<LogEntry> get lines => _lines;
  List<LogEntry> get visible => _visible;
  String get connection => _connection;
  String get serverStatus => _serverStatus;
  int? get appPid => _appPid;
  List<DeviceInfo> get devices => _devices;
  String? get activeDevice => _activeDevice;
  String? get pickedDevice => _pickedDevice;
  DeviceViewMode get viewMode => _viewMode;
  Map<String, DeviceTabState> get tabStates => Map.unmodifiable(_tabStates);
  List<FilterPreset> get presets => _presets;
  String get search => _search;
  String get minLevel => _minLevel;
  bool get paused => _paused;
  bool get wrap => _wrap;
  bool get autoScroll => _autoScroll;
  bool get useRegex => _useRegex;
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

  void scrollToBottom() {
    if (!_isAppActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_autoScroll && scrollController.hasClients) {
        scrollController.jumpTo(scrollController.position.maxScrollExtent);
      }
    });
  }

  void scrollToEnd() {
    _autoScroll = true;
    notifyListeners();
    scrollToBottom();
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
        final targetSerial = serial ?? _activeDevice;
        if (targetSerial != null) {
          final tab = _getOrCreateTab(targetSerial);
          tab.lines
            ..clear()
            ..addAll(lines);
        }
        if (targetSerial == null || targetSerial == _activeDevice) {
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
        final targetSerial = serial ?? _activeDevice;
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
            _activeDevice != null &&
            targetSerial != _activeDevice) {
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
        if (passing.isNotEmpty) {
          if (excess > 0 && _visible.isNotEmpty) {
            final minSeq = _lines.first.seq;
            var trimCount = 0;
            while (trimCount < _visible.length &&
                _visible[trimCount].seq < minSeq) {
              trimCount++;
            }
            if (trimCount > 0) {
              _visible = [..._visible.skip(trimCount), ...passing];
            } else {
              _visible = [..._visible, ...passing];
            }
          } else {
            _visible = [..._visible, ...passing];
          }
        } else if (excess > 0 && _visible.isNotEmpty) {
          final minSeq = _lines.first.seq;
          var trimCount = 0;
          while (trimCount < _visible.length &&
              _visible[trimCount].seq < minSeq) {
            trimCount++;
          }
          if (trimCount > 0) {
            _visible = _visible.sublist(trimCount);
          }
        }

        // Phase 2.1: Exactly one notifyListeners per incoming batch
        notifyListeners();
        if (_autoScroll) {
          scrollToBottom();
        }
        break;

      case ClearMessage(:final serial):
        final targetSerial = serial ?? _activeDevice;
        if (targetSerial != null) {
          _tabStates[targetSerial]?.lines.clear();
        }
        if (targetSerial == null || targetSerial == _activeDevice) {
          _lines.clear();
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
        _devices = devices;
        if (_activeDevice == null ||
            !_devices.any((d) => d.serial == _activeDevice)) {
          _activeDevice =
              activeDevice ??
              (_devices.isNotEmpty ? _devices.first.serial : null);
        }
        final activeSerials = _devices.map((d) => d.serial).toSet();
        _tabStates.removeWhere((k, _) => !activeSerials.contains(k));
        notifyListeners();
        break;

      case HandshakeMessage():
        break;

      case UnknownMessage():
        break;
    }
  }

  void selectDeviceTab(String serial) {
    if (_activeDevice == serial) return;

    // 1. Save current active tab filter state
    if (_activeDevice != null) {
      final currentTab = _getOrCreateTab(_activeDevice!);
      currentTab.search = _search;
      currentTab.minLevel = _minLevel;
      currentTab.packageFilter = pkgController.text.trim();
      currentTab.useRegex = _useRegex;
      currentTab.autoScroll = _autoScroll;
      currentTab.paused = _paused;
    }

    // 2. Switch to target device tab
    _activeDevice = serial;
    _pickedDevice = serial;
    final tab = _getOrCreateTab(serial);

    _search = tab.search;
    searchController.text = tab.search;
    pkgController.text = tab.packageFilter;
    _minLevel = tab.minLevel;
    _useRegex = tab.useRegex;
    _autoScroll = tab.autoScroll;
    _paused = tab.paused;

    _updateFilterCache();
    _lines
      ..clear()
      ..addAll(tab.lines);

    _recompute();
    sendCommand(DeviceCommand(serial));
    notifyListeners();
  }

  void setViewMode(DeviceViewMode mode) {
    if (_viewMode == mode) return;
    _viewMode = mode;
    notifyListeners();
  }

  void toggleViewMode() {
    _viewMode =
        _viewMode == DeviceViewMode.singleOrTabs
            ? DeviceViewMode.grid
            : DeviceViewMode.singleOrTabs;
    notifyListeners();
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
    _cachedQuery = _search;
    _cachedQueryLower = _search.toLowerCase();
    _cachedUseRegex = _useRegex;

    if (_cachedUseRegex && _cachedQuery.isNotEmpty) {
      try {
        _cachedRegex = RegExp(_cachedQuery, caseSensitive: false);
      } catch (_) {
        _cachedRegex = null;
      }
    } else {
      _cachedRegex = null;
    }
  }

  bool _matchesFilter(LogEntry e) {
    if (e.rank < _cachedMinRank) return false;
    if (_cachedQuery.isEmpty) return true;
    if (_cachedUseRegex) {
      final re = _cachedRegex;
      return re != null && (re.hasMatch(e.msg) || re.hasMatch(e.tag));
    }
    return e.msg.toLowerCase().contains(_cachedQueryLower) ||
        e.tag.toLowerCase().contains(_cachedQueryLower);
  }

  void _recompute() {
    _updateFilterCache();
    _visible = _lines.where(_matchesFilter).toList(growable: false);
    notifyListeners();
  }

  // User Actions
  void setSearch(String v) {
    _search = v;
    _recompute();
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
    _pickedDevice = serial;
    notifyListeners();
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
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _reconnect?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
    searchController.dispose();
    pkgController.dispose();
    stopBridge();
    super.dispose();
  }
}
