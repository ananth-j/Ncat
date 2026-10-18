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

/// Central state controller for logcat streaming, filtering, presets, and export.
class LogcatController extends ChangeNotifier {
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

  List<FilterPreset> _presets = const [];

  String _search = '';
  String _minLevel = 'V';
  bool _paused = false;
  bool _wrap = true;
  bool _autoScroll = true;
  bool _useRegex = false;

  LogColumnConfig _columns = const LogColumnConfig();

  // Getters
  List<LogEntry> get lines => _lines;
  List<LogEntry> get visible => _visible;
  String get connection => _connection;
  String get serverStatus => _serverStatus;
  int? get appPid => _appPid;
  List<DeviceInfo> get devices => _devices;
  String? get activeDevice => _activeDevice;
  String? get pickedDevice => _pickedDevice;
  List<FilterPreset> get presets => _presets;
  String get search => _search;
  String get minLevel => _minLevel;
  bool get paused => _paused;
  bool get wrap => _wrap;
  bool get autoScroll => _autoScroll;
  bool get useRegex => _useRegex;
  LogColumnConfig get columns => _columns;

  void init() {
    scrollController.addListener(_onScroll);
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
      case HistoryMessage(:final lines):
        _lines
          ..clear()
          ..addAll(lines);
        _recompute();
        if (_autoScroll) {
          scrollToBottom();
        }
        break;

      case LogBatchMessage(:final lines):
        if (_paused) return;
        _lines.addAll(lines);
        final maxCapacity = _autoScroll ? kMaxLines : kMaxLines * 2;
        if (_lines.length > maxCapacity) {
          _lines.removeRange(0, _lines.length - maxCapacity);
        }
        _recompute();
        if (_autoScroll) {
          scrollToBottom();
        }
        break;

      case ClearMessage():
        _lines.clear();
        _recompute();
        break;

      case StatusMessage(
          :final status,
          :final pid,
          :final devices,
          :final activeDevice
        ):
        _serverStatus = status;
        _appPid = pid;
        _devices = devices;
        _activeDevice = activeDevice;
        notifyListeners();
        break;

      case UnknownMessage():
        break;
    }
  }

  void _recompute() {
    final min = kLevels.indexOf(_minLevel);
    final q = _search;
    final qLower = q.toLowerCase();

    RegExp? re;
    if (_useRegex && q.isNotEmpty) {
      try {
        re = RegExp(q, caseSensitive: false);
      } catch (_) {
        // Invalid regex while typing
      }
    }

    _visible = _lines
        .where((e) {
          if (e.rank < min) return false;
          if (q.isEmpty) return true;
          if (_useRegex) {
            return re != null && (re.hasMatch(e.msg) || re.hasMatch(e.tag));
          }
          return e.msg.toLowerCase().contains(qLower) ||
              e.tag.toLowerCase().contains(qLower);
        })
        .toList(growable: false);

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
    sendCommand(FilterCommand(pkgController.text.trim()));
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

  void applyDevice(String? serial) {
    _pickedDevice = serial;
    notifyListeners();
    sendCommand(DeviceCommand(serial));
  }

  void clearLogs() {
    sendCommand(const ClearCommand());
  }

  void restartAdb() {
    sendCommand(const RestartCommand());
  }

  void updateColumns(LogColumnConfig next) {
    _columns = next;
    notifyListeners();
    saveColumnConfig(next);
  }

  // Presets
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

  // Export
  Future<String> exportLogs() async {
    final buf = StringBuffer();
    for (final e in _visible) {
      final parts = <String>[];
      if (_columns.showTime) parts.add(e.time);
      if (_columns.showPidTid) parts.add('${e.pid}-${e.tid}');
      if (_columns.showPackage) {
        final pkg = e.pkg ??
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
      final pkg = e.pkg ??
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
