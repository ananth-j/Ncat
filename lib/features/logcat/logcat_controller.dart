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
import 'models/log_tab_state.dart';
import 'models/noise_filter.dart';

// Re-export device, tab, and noise models for backward compatibility
export '../devices/device_controller.dart'
    show DeviceViewMode, DeviceTabState, DeviceController;
export 'models/log_tab_state.dart' show LogTabState;
export 'models/noise_filter.dart' show NoiseFilterMode, NoiseFilter;

/// Split-pane layout orientation for viewing two log tabs simultaneously.
enum LogSplitAxis { none, horizontal, vertical }

/// Central state controller for logcat streaming, per-tab filtering, split panes,
/// presets, and export.
class LogcatController extends ChangeNotifier with WidgetsBindingObserver {
  LogcatController({
    int maxLines = kMaxLines,
    DeviceController? deviceController,
  }) : _maxLines = maxLines,
       _deviceController = deviceController ?? DeviceController() {
    _deviceController.addListener(_onDeviceChanged);
    _attachTabListeners(_tabs.first);
  }

  final int _maxLines;
  final DeviceController _deviceController;

  void _onDeviceChanged() {
    notifyListeners();
  }

  final Map<String, VoidCallback> _scrollListeners = {};
  final Map<String, Timer> _searchDebounces = {};

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;

  String _connection = 'connecting';
  String _serverStatus = '';
  int? _appPid;
  String? _lastStatusPackage;

  // Multi-tab & split state (Android Studio Logcat-style)
  final List<LogTabState> _tabs = [
    LogTabState(id: 'tab_1', title: 'Logcat 1'),
  ];
  String _activeTabId = 'tab_1';
  String _pane0TabId = 'tab_1';
  String? _pane1TabId;
  int _focusedPane = 0;
  LogSplitAxis _splitAxis = LogSplitAxis.none;
  double _splitRatio = 0.5;
  int _nextTabCounter = 2;
  bool _userModifiedTabs = false;

  DeviceTabState _getOrCreateDeviceBuffer(String serial) =>
      _deviceController.getOrCreateTab(serial);

  List<FilterPreset> _presets = const [];
  LogColumnConfig _columns = const LogColumnConfig();

  // Background mode tracking (Phase 2.4)
  bool _isAppActive = true;
  bool _needsUiSync = false;

  // Fallback empty notifiers when not split
  final ValueNotifier<List<LogEntry>> _emptyVisibleNotifier =
      ValueNotifier<List<LogEntry>>(const []);
  final ValueNotifier<LogStats> _emptyStatsNotifier = ValueNotifier<LogStats>(
    (total: 0, visible: 0, hiddenNoise: 0),
  );
  final ScrollController _dummyScrollController = ScrollController();

  // Active tab delegated getters
  int get maxLines => _maxLines;
  List<LogEntry> get lines => activeTab.lines;
  List<LogEntry> get visible => activeTab.visible;
  ValueNotifier<List<LogEntry>> get visibleNotifier =>
      activeTab.visibleNotifier;
  ValueNotifier<LogStats> get statsNotifier => activeTab.statsNotifier;
  ScrollController get scrollController => activeTab.scrollController;
  TextEditingController get searchController => activeTab.searchController;
  TextEditingController get pkgController => activeTab.pkgController;

  String get connection => _connection;
  String get serverStatus => _serverStatus;

  /// Effective PID for the active tab's package filter on its target device.
  int? get appPid => appPidForTab(activeTab);

  int? appPidForTab(LogTabState tab) {
    final pkg = tab.packageFilter.trim();
    final serial = _effectiveSerialFor(tab);
    if (pkg.isNotEmpty) {
      if (serial != null) {
        final cached = _deviceController.tabStates[serial]?.packagePids[pkg];
        if (cached != null) return cached;
      }
      return _lastStatusPackage == pkg ? _appPid : null;
    }
    return _appPid;
  }

  List<DeviceInfo> get devices => _deviceController.devices;
  String? get activeDevice => activeTabSerial ?? _deviceController.activeDevice;
  String? get pickedDevice =>
      activeTab.deviceSerial ?? _deviceController.pickedDevice;
  DeviceViewMode get viewMode => _deviceController.viewMode;
  Map<String, DeviceTabState> get tabStates => _deviceController.tabStates;
  DeviceController get deviceController => _deviceController;
  List<FilterPreset> get presets => _presets;
  String get search => activeTab.search;
  String get minLevel => activeTab.minLevel;
  bool get paused => activeTab.paused;
  bool get wrap => activeTab.wrap;
  bool get autoScroll => activeTab.autoScroll;
  bool get useRegex => activeTab.useRegex;
  NoiseFilterMode get noiseMode => activeTab.noiseMode;
  bool get reduceNoise => activeTab.noiseMode == NoiseFilterMode.reduce;
  int get hiddenNoiseCount => activeTab.hiddenNoiseCount;
  LogColumnConfig get columns => _columns;

  // Multi-tab & split getters
  List<LogTabState> get logTabs => List.unmodifiable(_tabs);
  String get activeTabId => _activeTabId;
  LogTabState get activeTab => _tabById(_activeTabId);
  int get activeTabIndex =>
      _tabs.indexWhere((t) => t.id == activeTab.id).clamp(0, _tabs.length - 1);
  String? get activeTabSerial => _effectiveSerialFor(activeTab);

  LogSplitAxis get splitAxis => _splitAxis;
  double get splitRatio => _splitRatio;
  int get focusedPane => _focusedPane;
  bool get isSplit => _splitAxis != LogSplitAxis.none && secondaryTab != null;
  LogTabState get primaryTab => _tabById(_pane0TabId);
  LogTabState? get secondaryTab =>
      _pane1TabId == null ? null : _tabByIdOrNull(_pane1TabId!);

  // Pane-specific accessors
  ValueNotifier<List<LogEntry>> get primaryVisibleNotifier =>
      primaryTab.visibleNotifier;
  ValueNotifier<LogStats> get primaryStatsNotifier => primaryTab.statsNotifier;
  ScrollController get primaryScrollController => primaryTab.scrollController;
  List<LogEntry> get primaryLines => primaryTab.lines;
  List<LogEntry> get primaryVisible => primaryTab.visible;

  ValueNotifier<List<LogEntry>> get secondaryVisibleNotifier =>
      secondaryTab?.visibleNotifier ?? _emptyVisibleNotifier;
  ValueNotifier<LogStats> get secondaryStatsNotifier =>
      secondaryTab?.statsNotifier ?? _emptyStatsNotifier;
  ScrollController get secondaryScrollController =>
      secondaryTab?.scrollController ?? _dummyScrollController;
  List<LogEntry> get secondaryLines => secondaryTab?.lines ?? const [];
  List<LogEntry> get secondaryVisible => secondaryTab?.visible ?? const [];

  LogTabState _tabById(String id) =>
      _tabs.firstWhere((t) => t.id == id, orElse: () => _tabs.first);

  LogTabState? _tabByIdOrNull(String id) {
    for (final t in _tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  String? _effectiveSerialFor(LogTabState tab) =>
      tab.deviceSerial ?? _deviceController.activeDevice;

  void _attachTabListeners(LogTabState tab) {
    if (_scrollListeners.containsKey(tab.id)) return;
    void listener() => _onTabScroll(tab);
    _scrollListeners[tab.id] = listener;
    tab.scrollController.addListener(listener);
  }

  void _detachAndDisposeTab(LogTabState tab) {
    _searchDebounces.remove(tab.id)?.cancel();
    final listener = _scrollListeners.remove(tab.id);
    if (listener != null && !tab.isDisposed) {
      tab.scrollController.removeListener(listener);
    }
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) => tab.dispose());
    } catch (_) {
      tab.dispose();
    }
  }

  void init() {
    WidgetsBinding.instance.addObserver(this);
    _updateFilterCache(activeTab);

    loadColumnConfig().then((c) {
      _columns = c;
      notifyListeners();
    });
    loadFilterPresets().then((p) {
      _presets = p;
      notifyListeners();
    });
    loadLogTabs().then((saved) {
      if (!_userModifiedTabs && saved.tabs.isNotEmpty) {
        final oldTabs = List<LogTabState>.of(_tabs);
        _tabs
          ..clear()
          ..addAll(saved.tabs);
        for (final t in _tabs) {
          _attachTabListeners(t);
        }
        for (final old in oldTabs) {
          _detachAndDisposeTab(old);
        }
        final targetId =
            saved.activeTabId != null &&
                    _tabs.any((t) => t.id == saved.activeTabId)
                ? saved.activeTabId!
                : _tabs.first.id;
        _pane0TabId = targetId;
        _activeTabId = targetId;
        _focusedPane = 0;
        _nextTabCounter = _computeNextTabCounter(_tabs);
        _syncTabLinesFromBuffer(activeTab);
        _recomputeTab(activeTab);
      }
    });
    _initBridgeAndConnect();
  }

  static int _computeNextTabCounter(List<LogTabState> tabs) {
    var maxNum = tabs.length;
    final re = RegExp(r'(\d+)$');
    for (final t in tabs) {
      final m = re.firstMatch(t.id) ?? re.firstMatch(t.title);
      if (m != null) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n > maxNum) maxNum = n;
      }
    }
    return maxNum + 1;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_isAppActive != active) {
      _isAppActive = active;
      if (_isAppActive && _needsUiSync) {
        _needsUiSync = false;
        _recomputeVisiblePanes();
      }
    }
  }

  void _onTabScroll(LogTabState tab) {
    if (!tab.scrollController.hasClients) return;
    final max = tab.scrollController.position.maxScrollExtent;
    final current = tab.scrollController.offset;
    final atBottom = max <= 0 || current >= (max - 50);

    if (atBottom && !tab.autoScroll) {
      tab.autoScroll = true;
      notifyListeners();
    } else if (!atBottom && tab.autoScroll) {
      tab.autoScroll = false;
      tab.scrollOffset = current;
      notifyListeners();
    } else if (!tab.autoScroll) {
      tab.scrollOffset = current;
    }
  }

  static const double _rowExtent = 23.0;

  void scrollToBottom([String? tabId]) {
    final tab = tabId != null ? (_tabByIdOrNull(tabId) ?? activeTab) : activeTab;
    if (!_isAppActive || !tab.scrollController.hasClients) return;

    if (!tab.wrap && tab.visible.isNotEmpty) {
      final viewportHeight = tab.scrollController.position.viewportDimension;
      final totalHeight = tab.visible.length * _rowExtent;
      final target = (totalHeight - viewportHeight).clamp(
        0.0,
        double.infinity,
      );
      tab.scrollController.jumpTo(target);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!tab.isDisposed && tab.autoScroll && tab.scrollController.hasClients) {
          tab.scrollController.jumpTo(
            tab.scrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }

  void scrollToEndForTab(String tabId) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    scrollToBottom(tab.id);
    tab.autoScroll = true;
    notifyListeners();
  }

  void scrollToEnd() => scrollToEndForTab(activeTabId);

  void scrollToTopForTab(String tabId) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    tab.autoScroll = false;
    tab.scrollOffset = 0.0;
    notifyListeners();
    if (tab.scrollController.hasClients) {
      tab.scrollController.jumpTo(0);
    }
  }

  void scrollToTop() => scrollToTopForTab(activeTabId);

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

  List<LogTabState> get _visiblePaneTabs {
    if (isSplit) {
      final sec = secondaryTab!;
      if (sec.id != primaryTab.id) return [primaryTab, sec];
    }
    return [primaryTab];
  }

  @visibleForTesting
  void handleMessage(BridgeMessage message) {
    switch (message) {
      case HistoryMessage(:final lines, :final serial):
        final targetSerial = serial ?? _deviceController.activeDevice;
        if (targetSerial != null) {
          final devBuf = _getOrCreateDeviceBuffer(targetSerial);
          devBuf.lines
            ..clear()
            ..addAll(lines);
        }
        for (final tab in _visiblePaneTabs) {
          _applyHistoryToTab(tab, lines, targetSerial);
        }
        break;

      case LogBatchMessage(:final lines, :final serial):
        final targetSerial = serial ?? _deviceController.activeDevice;
        if (targetSerial == null) {
          final hasUnpaused = _visiblePaneTabs.any((t) => !t.paused);
          if (!hasUnpaused) return;
        } else {
          final matchingTabs =
              _tabs
                  .where((t) => _effectiveSerialFor(t) == targetSerial)
                  .toList();
          final hasUnpausedTab =
              matchingTabs.isEmpty || matchingTabs.any((t) => !t.paused);
          if (!hasUnpausedTab) return;

          final devBuf = _getOrCreateDeviceBuffer(targetSerial);
          devBuf.lines.addAll(lines);
          final anyScrollPaused = matchingTabs.any((t) => !t.autoScroll);
          final cap = anyScrollPaused ? _maxLines * 2 : _maxLines;
          final devExcess = devBuf.lines.length - cap;
          if (devExcess > 0) {
            devBuf.lines.removeRange(0, devExcess);
          }
        }

        for (final tab in _visiblePaneTabs) {
          _applyBatchToTab(tab, lines, targetSerial);
        }
        break;

      case ClearMessage(:final serial):
        final targetSerial = serial ?? _deviceController.activeDevice;
        if (targetSerial != null) {
          _deviceController.tabStates[targetSerial]?.lines.clear();
          for (final t in _tabs) {
            if (_effectiveSerialFor(t) == targetSerial) {
              t.clearedAfterSeq = null;
              t.pausedBufferSnapshot = null;
            }
          }
        } else {
          activeTab.clearedAfterSeq = null;
          activeTab.pausedBufferSnapshot = null;
        }

        for (final tab in _visiblePaneTabs) {
          final paneSerial = _effectiveSerialFor(tab);
          if (targetSerial == null ||
              paneSerial == null ||
              targetSerial == paneSerial) {
            tab.lines.clear();
            tab.hiddenNoiseCount = 0;
            _recomputeTab(tab, notifyController: tab.id == _activeTabId);
          }
        }
        break;

      case StatusMessage(
        :final status,
        :final package,
        :final pid,
        :final devices,
        :final activeDevice,
        :final serial,
      ):
        _serverStatus = status;
        _appPid = pid;
        _lastStatusPackage = package;
        final pidSerial = serial ?? activeDevice ?? _deviceController.activeDevice;
        if (pidSerial != null) {
          _deviceController.setPackagePid(pidSerial, package, pid);
        }
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

  void _applyHistoryToTab(
    LogTabState tab,
    List<LogEntry> lines,
    String? targetSerial,
  ) {
    final tabSerial = _effectiveSerialFor(tab);
    if (targetSerial != null &&
        tabSerial != null &&
        targetSerial != tabSerial) {
      return;
    }
    if (tab.paused) return;

    tab.lines
      ..clear()
      ..addAll(lines);
    _recomputeTab(tab, notifyController: tab.id == _activeTabId);
    if (tab.autoScroll) {
      scrollToBottom(tab.id);
    }
  }

  void _applyBatchToTab(
    LogTabState tab,
    List<LogEntry> lines,
    String? targetSerial,
  ) {
    final tabSerial = _effectiveSerialFor(tab);
    if (targetSerial != null &&
        tabSerial != null &&
        targetSerial != tabSerial) {
      return;
    }
    if (tab.paused) return;

    tab.lines.addAll(lines);
    final maxCapacity = tab.autoScroll ? _maxLines : _maxLines * 2;
    final excess = tab.lines.length - maxCapacity;
    if (excess > 0) {
      tab.lines.removeRange(0, excess);
    }

    if (!_isAppActive) {
      _needsUiSync = true;
      return;
    }

    final currentPkg = tab.packageFilter.trim();
    final currentAppPid = appPidForTab(tab);
    final isReduced = tab.noiseMode == NoiseFilterMode.reduce;
    final needsNoiseCheck =
        isReduced ||
        tab.noiseMode == NoiseFilterMode.onlyNoise ||
        tab.cachedQuery.hasNoiseTerm;
    final clearedAfter = tab.clearedAfterSeq;
    final passing = <LogEntry>[];

    for (final l in lines) {
      if (clearedAfter != null && l.seq <= clearedAfter) continue;
      final isNoise =
          needsNoiseCheck
              ? NoiseFilter.isNoise(
                l,
                appPid: currentAppPid,
                packageFilter: currentPkg,
              )
              : false;
      if (_matchesEntry(
        l,
        tab: tab,
        currentPkg: currentPkg,
        tabAppPid: currentAppPid,
        isNoise: isNoise,
      )) {
        passing.add(l);
      } else if (isReduced && isNoise) {
        tab.hiddenNoiseCount++;
      }
    }
    if (excess > 0 && tab.hiddenNoiseCount > tab.lines.length) {
      tab.hiddenNoiseCount = (tab.lines.length - tab.visible.length).clamp(
        0,
        tab.lines.length,
      );
    }
    if (excess > 0) {
      _trimVisibleToBufferStart(tab);
    }
    if (passing.isNotEmpty) {
      tab.visible.addAll(passing);
    }

    tab.publishVisibleAndStats();
    if (tab.autoScroll) {
      scrollToBottom(tab.id);
    }
  }

  // ---------------------------------------------------------------------------
  // Multi-tab & split-pane management
  // ---------------------------------------------------------------------------

  void _syncTabLinesFromBuffer(LogTabState tab) {
    if (tab.paused && tab.pausedBufferSnapshot != null) {
      tab.lines
        ..clear()
        ..addAll(tab.pausedBufferSnapshot!);
      return;
    }
    final serial = _effectiveSerialFor(tab);
    if (serial != null) {
      final devBuf = _getOrCreateDeviceBuffer(serial);
      tab.lines
        ..clear()
        ..addAll(devBuf.lines);
    }
  }

  void _persistTabs() {
    unawaited(saveLogTabs(_tabs, _activeTabId));
  }

  /// Adds a new log tab and opens it in the currently focused pane.
  String addTab({
    String? deviceSerial,
    FilterPreset? preset,
    bool duplicateCurrent = false,
    String? title,
  }) {
    _userModifiedTabs = true;

    final num = _nextTabCounter++;
    final id = 'tab_$num';
    final current = activeTab;

    final LogTabState newTab;
    if (duplicateCurrent) {
      newTab = current.copyWith(
        id: id,
        title: title ?? '${current.displayTitle} ($num)',
        isCustomTitle: title != null || current.isCustomTitle,
        paused: false,
      );
    } else if (preset != null) {
      newTab = LogTabState(
        id: id,
        title: title ?? preset.name,
        isCustomTitle: true,
        deviceSerial: deviceSerial ?? current.deviceSerial,
        packageFilter: preset.package,
        search: preset.search,
        minLevel: preset.minLevel,
        useRegex: preset.useRegex,
      );
    } else {
      newTab = LogTabState(
        id: id,
        title: title ?? 'Logcat $num',
        isCustomTitle: title != null,
        deviceSerial: deviceSerial ?? current.deviceSerial,
      );
    }

    _attachTabListeners(newTab);
    _tabs.add(newTab);
    selectTab(newTab.id);
    return newTab.id;
  }

  String duplicateTab(String tabId) {
    final idx = _tabs.indexWhere((t) => t.id == tabId);
    if (idx < 0) return addTab(duplicateCurrent: true);
    if (_activeTabId != tabId) {
      selectTab(tabId);
    }
    return addTab(duplicateCurrent: true);
  }

  void reorderTab(String draggedTabId, int newIndex) {
    final oldIndex = _tabs.indexWhere((t) => t.id == draggedTabId);
    if (oldIndex < 0) return;
    var target = newIndex.clamp(0, _tabs.length);
    if (oldIndex < target) target -= 1;
    if (oldIndex == target) return;

    _userModifiedTabs = true;
    final moved = _tabs.removeAt(oldIndex);
    _tabs.insert(target.clamp(0, _tabs.length), moved);
    _persistTabs();
    notifyListeners();
  }

  void splitWithTab(
    String tabId,
    LogSplitAxis axis, {
    bool putInPrimary = false,
  }) {
    if (axis == LogSplitAxis.none) {
      closeSplit();
      return;
    }
    if (_tabByIdOrNull(tabId) == null) return;

    _userModifiedTabs = true;

    if (putInPrimary) {
      final previousPrimary = _pane0TabId;
      final secondId =
          previousPrimary != tabId
              ? previousPrimary
              : _findOrCreateSiblingTabId(tabId);
      _pane0TabId = tabId;
      _pane1TabId = secondId;
      _splitAxis = axis;
      _focusedPane = 0;
      _activeTabId = tabId;
    } else {
      final secondId =
          tabId != _pane0TabId ? tabId : _findOrCreateSiblingTabId(tabId);
      _pane1TabId = secondId;
      _splitAxis = axis;
      _focusedPane = 1;
      _activeTabId = secondId;
    }

    _syncTabLinesFromBuffer(primaryTab);
    if (secondaryTab != null) {
      _syncTabLinesFromBuffer(secondaryTab!);
    }
    _recomputeVisiblePanes();
    _persistTabs();
  }

  String _findOrCreateSiblingTabId(String excludeTabId) {
    for (final t in _tabs) {
      if (t.id != excludeTabId) return t.id;
    }
    final num = _nextTabCounter++;
    final id = 'tab_$num';
    final base = _tabById(excludeTabId);
    final created = base.copyWith(
      id: id,
      title: 'Logcat $num',
      isCustomTitle: false,
      paused: false,
    );
    _attachTabListeners(created);
    _tabs.add(created);
    return id;
  }

  void toggleSplit([LogSplitAxis axis = LogSplitAxis.horizontal]) {
    if (isSplit) {
      closeSplit();
    } else {
      splitWithTab(activeTabId, axis);
    }
  }

  void closeSplit() {
    if (!isSplit) return;
    if (_focusedPane == 1 && _pane1TabId != null) {
      _pane0TabId = _pane1TabId!;
    }
    _pane1TabId = null;
    _splitAxis = LogSplitAxis.none;
    _focusedPane = 0;
    _activeTabId = _pane0TabId;
    _syncTabLinesFromBuffer(activeTab);
    _recomputeTab(activeTab);
    _persistTabs();
  }

  void setSplitRatio(double ratio) {
    final clamped = ratio.clamp(0.2, 0.8);
    if ((_splitRatio - clamped).abs() < 0.001) return;
    _splitRatio = clamped;
    notifyListeners();
  }

  void focusPane(int paneIndex) {
    if (!isSplit) return;
    if (paneIndex != 0 && paneIndex != 1) return;
    if (_focusedPane == paneIndex) return;

    _focusedPane = paneIndex;
    _activeTabId = paneIndex == 1 ? _pane1TabId! : _pane0TabId;

    final nextSerial = activeTabSerial;
    if (nextSerial != null && nextSerial != _deviceController.activeDevice) {
      _deviceController.setActiveDevice(nextSerial);
      sendCommand(DeviceCommand(nextSerial));
    }
    notifyListeners();
  }

  void selectTab(String tabId) {
    final target = _tabByIdOrNull(tabId);
    if (target == null) return;

    if (isSplit) {
      if (_focusedPane == 0 && _pane1TabId == tabId) {
        focusPane(1);
        return;
      }
      if (_focusedPane == 1 && _pane0TabId == tabId) {
        focusPane(0);
        return;
      }
    }

    if (_activeTabId == tabId) return;

    _userModifiedTabs = true;
    final prevSerial = activeTabSerial;
    _activeTabId = tabId;
    if (_focusedPane == 1 && isSplit) {
      _pane1TabId = tabId;
    } else {
      _pane0TabId = tabId;
    }

    final nextSerial = _effectiveSerialFor(target);
    if (nextSerial != null && nextSerial != _deviceController.activeDevice) {
      _deviceController.setActiveDevice(nextSerial);
      sendCommand(DeviceCommand(nextSerial));
    } else if (nextSerial != null && nextSerial != prevSerial) {
      sendCommand(DeviceCommand(nextSerial));
    }

    if (target.packageFilter.isNotEmpty && nextSerial != null) {
      final cachedPid =
          _deviceController.tabStates[nextSerial]?.packagePids[target
              .packageFilter];
      if (cachedPid == null) {
        sendCommand(FilterCommand(target.packageFilter, serial: nextSerial));
      }
    }

    _syncTabLinesFromBuffer(target);
    _recomputeTab(target);

    if (target.autoScroll) {
      scrollToBottom(target.id);
    } else {
      final offset = target.scrollOffset;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!target.isDisposed && target.scrollController.hasClients) {
          final max = target.scrollController.position.maxScrollExtent;
          target.scrollController.jumpTo(offset.clamp(0.0, max));
        }
      });
    }

    _persistTabs();
  }

  void selectNextTab() {
    if (_tabs.length <= 1) return;
    final nextIdx = (activeTabIndex + 1) % _tabs.length;
    selectTab(_tabs[nextIdx].id);
  }

  void selectPreviousTab() {
    if (_tabs.length <= 1) return;
    final prevIdx = (activeTabIndex - 1 + _tabs.length) % _tabs.length;
    selectTab(_tabs[prevIdx].id);
  }

  void selectTabByIndex(int index) {
    if (index < 0 || index >= _tabs.length) return;
    selectTab(_tabs[index].id);
  }

  void closeTab(String tabId) {
    if (_tabs.length <= 1) return;
    final idx = _tabs.indexWhere((t) => t.id == tabId);
    if (idx < 0) return;

    _userModifiedTabs = true;

    if (isSplit) {
      if (_pane1TabId == tabId) {
        final removed = _tabs.removeAt(idx);
        _pane1TabId = null;
        _splitAxis = LogSplitAxis.none;
        _focusedPane = 0;
        _activeTabId = _pane0TabId;
        _syncTabLinesFromBuffer(activeTab);
        _recomputeTab(activeTab);
        _detachAndDisposeTab(removed);
        _persistTabs();
        return;
      }
      if (_pane0TabId == tabId) {
        final removed = _tabs.removeAt(idx);
        _pane0TabId = _pane1TabId!;
        _pane1TabId = null;
        _splitAxis = LogSplitAxis.none;
        _focusedPane = 0;
        _activeTabId = _pane0TabId;
        _syncTabLinesFromBuffer(activeTab);
        _recomputeTab(activeTab);
        _detachAndDisposeTab(removed);
        _persistTabs();
        return;
      }
    }

    if (_activeTabId == tabId) {
      final fallbackIdx = idx > 0 ? idx - 1 : 1;
      selectTab(_tabs[fallbackIdx].id);
    }
    final removed = _tabs.removeAt(_tabs.indexWhere((t) => t.id == tabId));
    _detachAndDisposeTab(removed);
    _persistTabs();
    notifyListeners();
  }

  void closeOtherTabs(String tabId) {
    if (!_tabs.any((t) => t.id == tabId) || _tabs.length <= 1) return;
    _userModifiedTabs = true;
    if (isSplit) {
      _pane1TabId = null;
      _splitAxis = LogSplitAxis.none;
      _focusedPane = 0;
    }
    _pane0TabId = tabId;
    if (_activeTabId != tabId) {
      selectTab(tabId);
    }
    final toRemove = _tabs.where((t) => t.id != tabId).toList();
    _tabs.removeWhere((t) => t.id != tabId);
    for (final t in toRemove) {
      _detachAndDisposeTab(t);
    }
    _persistTabs();
    notifyListeners();
  }

  void closeTabsToRight(String tabId) {
    final idx = _tabs.indexWhere((t) => t.id == tabId);
    if (idx < 0 || idx >= _tabs.length - 1) return;
    _userModifiedTabs = true;
    if (activeTabIndex > idx) {
      selectTab(tabId);
    }
    final toRemove = _tabs.sublist(idx + 1);
    _tabs.removeRange(idx + 1, _tabs.length);
    for (final t in toRemove) {
      _detachAndDisposeTab(t);
    }
    if (_pane1TabId != null && _tabByIdOrNull(_pane1TabId!) == null) {
      _pane1TabId = null;
      _splitAxis = LogSplitAxis.none;
      _focusedPane = 0;
    }
    _persistTabs();
    notifyListeners();
  }

  void renameTab(String tabId, String title) {
    final idx = _tabs.indexWhere((t) => t.id == tabId);
    if (idx < 0) return;
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      _tabs[idx].isCustomTitle = false;
      _tabs[idx].title = 'Logcat ${idx + 1}';
    } else {
      _tabs[idx].isCustomTitle = true;
      _tabs[idx].title = trimmed;
    }
    _userModifiedTabs = true;
    _persistTabs();
    notifyListeners();
  }

  void setTabDeviceForTab(String tabId, String? serial) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    _userModifiedTabs = true;
    final normalized = (serial == null || serial.isEmpty) ? null : serial;
    tab.deviceSerial = normalized;
    tab.clearedAfterSeq = null;
    tab.pausedBufferSnapshot = null;

    if (tab.id == _activeTabId) {
      _deviceController.applyDevice(normalized);
    }
    final effective = _effectiveSerialFor(tab);
    if (effective != null) {
      sendCommand(DeviceCommand(effective));
    } else if (tab.id == _activeTabId) {
      sendCommand(const DeviceCommand(null));
    }

    _syncTabLinesFromBuffer(tab);
    _recomputeTab(tab);
    _persistTabs();
  }

  void setTabDevice(String? serial) => setTabDeviceForTab(activeTabId, serial);

  void selectDeviceTab(String serial) {
    final currentEffective = activeTabSerial;
    if (currentEffective == serial && activeTab.deviceSerial == serial) return;

    if (activeTab.deviceSerial == null && currentEffective != null) {
      activeTab.deviceSerial = currentEffective;
    }

    if (currentEffective == serial) {
      _deviceController.setActiveDevice(serial);
      notifyListeners();
      return;
    }

    final existingIdx = _tabs.indexWhere((t) => t.deviceSerial == serial);
    if (existingIdx >= 0) {
      selectTab(_tabs[existingIdx].id);
      return;
    }

    final isFreshSingleTab =
        _tabs.length == 1 &&
        activeTab.deviceSerial == null &&
        activeTab.lines.isEmpty &&
        activeTab.search.isEmpty &&
        activeTab.pkgController.text.trim().isEmpty;
    if (isFreshSingleTab) {
      setTabDevice(serial);
    } else {
      addTab(deviceSerial: serial);
    }
  }

  void setViewMode(DeviceViewMode mode) {
    _deviceController.setViewMode(mode);
  }

  void toggleViewMode() {
    _deviceController.toggleViewMode();
  }

  void _updateFilterCache(LogTabState tab) {
    tab.cachedMinRank = switch (tab.minLevel) {
      'V' => 0,
      'D' => 1,
      'I' => 2,
      'W' => 3,
      'E' => 4,
      'F' || 'S' => 5,
      _ => kLevels.indexOf(tab.minLevel).clamp(0, kLevels.length - 1),
    };
    tab.cachedQuery = LogQuery(tab.search, useRegex: tab.useRegex);
  }

  void _trimVisibleToBufferStart(LogTabState tab) {
    if (tab.visible.isEmpty || tab.lines.isEmpty) return;
    final minSeq = tab.lines.first.seq;
    var trimCount = 0;
    while (trimCount < tab.visible.length && tab.visible[trimCount].seq < minSeq) {
      trimCount++;
    }
    if (trimCount > 0) {
      tab.visible.removeRange(0, trimCount);
    }
  }

  bool _matchesEntry(
    LogEntry e, {
    required LogTabState tab,
    required String currentPkg,
    required int? tabAppPid,
    required bool isNoise,
  }) {
    if (e.rank < tab.cachedMinRank) return false;

    if (currentPkg.isNotEmpty) {
      final lowerPkg = currentPkg.toLowerCase();
      final entryPkg = e.pkg?.toLowerCase();
      final matchesPkg = entryPkg != null && entryPkg.contains(lowerPkg);
      final matchesPid = tabAppPid != null && e.pid == tabAppPid;
      if (!matchesPkg && !matchesPid) return false;
    }

    if (!tab.cachedQuery.hasNoiseTerm) {
      if (tab.noiseMode == NoiseFilterMode.reduce && isNoise) {
        return false;
      } else if (tab.noiseMode == NoiseFilterMode.onlyNoise && !isNoise) {
        return false;
      }
    }

    for (final term in tab.cachedQuery.terms) {
      final field = term.field;
      final matched = switch (field) {
        'tag' => term.matches(e.tag),
        'message' => term.matches(e.msg),
        'package' => term.matches(
          e.pkg ?? (tabAppPid == e.pid ? currentPkg : ''),
        ),
        'process' => term.matches(
          e.pkg ?? (tabAppPid == e.pid ? currentPkg : '${e.pid}'),
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

  void _recomputeVisiblePanes() {
    for (final tab in _visiblePaneTabs) {
      _recomputeTab(tab, notifyController: false);
    }
    notifyListeners();
  }

  void _recomputeTab(LogTabState tab, {bool notifyController = true}) {
    _updateFilterCache(tab);
    tab.visible.clear();
    int hidden = 0;
    final isReduced = tab.noiseMode == NoiseFilterMode.reduce;
    final needsNoiseCheck =
        isReduced ||
        tab.noiseMode == NoiseFilterMode.onlyNoise ||
        tab.cachedQuery.hasNoiseTerm;
    final currentPkg = tab.packageFilter.trim();
    final currentAppPid = appPidForTab(tab);
    final clearedAfter = tab.clearedAfterSeq;

    for (final e in tab.lines) {
      if (clearedAfter != null && e.seq <= clearedAfter) continue;
      final isNoise =
          needsNoiseCheck
              ? NoiseFilter.isNoise(
                e,
                appPid: currentAppPid,
                packageFilter: currentPkg,
              )
              : false;
      if (_matchesEntry(
        e,
        tab: tab,
        currentPkg: currentPkg,
        tabAppPid: currentAppPid,
        isNoise: isNoise,
      )) {
        tab.visible.add(e);
      } else if (isReduced && isNoise) {
        hidden++;
      }
    }
    tab.hiddenNoiseCount = hidden;
    tab.publishVisibleAndStats();
    if (notifyController) {
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Per-tab User Actions (with active-tab convenience delegates)
  // ---------------------------------------------------------------------------

  void setNoiseModeForTab(String tabId, NoiseFilterMode mode) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null || tab.noiseMode == mode) return;
    tab.noiseMode = mode;
    _recomputeTab(tab);
    _persistTabs();
  }

  void setNoiseMode(NoiseFilterMode mode) =>
      setNoiseModeForTab(activeTabId, mode);

  void toggleReduceNoiseForTab(String tabId) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    setNoiseModeForTab(
      tabId,
      tab.noiseMode == NoiseFilterMode.reduce
          ? NoiseFilterMode.showAll
          : NoiseFilterMode.reduce,
    );
  }

  void toggleReduceNoise() => toggleReduceNoiseForTab(activeTabId);

  void setSearchForTab(String tabId, String v, {bool immediate = true}) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    tab.search = v;
    _searchDebounces.remove(tabId)?.cancel();
    if (immediate) {
      _recomputeTab(tab);
      _persistTabs();
    } else {
      _searchDebounces[tabId] = Timer(const Duration(milliseconds: 150), () {
        if (!tab.isDisposed) {
          _recomputeTab(tab);
          _persistTabs();
        }
      });
    }
  }

  void setSearch(String v, {bool immediate = true}) =>
      setSearchForTab(activeTabId, v, immediate: immediate);

  void setMinLevelForTab(String tabId, String v) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    tab.minLevel = v;
    _recomputeTab(tab);
    _persistTabs();
  }

  void setMinLevel(String v) => setMinLevelForTab(activeTabId, v);

  void toggleRegexForTab(String tabId) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    tab.useRegex = !tab.useRegex;
    _recomputeTab(tab);
    _persistTabs();
  }

  void toggleRegex() => toggleRegexForTab(activeTabId);

  void togglePausedForTab(String tabId) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    tab.paused = !tab.paused;
    if (tab.paused) {
      tab.pausedBufferSnapshot = List<LogEntry>.of(tab.lines);
      notifyListeners();
    } else {
      tab.pausedBufferSnapshot = null;
      _syncTabLinesFromBuffer(tab);
      _recomputeTab(tab);
    }
  }

  void togglePaused() => togglePausedForTab(activeTabId);

  void toggleWrapForTab(String tabId) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    tab.wrap = !tab.wrap;
    notifyListeners();
    _persistTabs();
  }

  void toggleWrap() => toggleWrapForTab(activeTabId);

  void applyPackageForTab(String tabId) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    final pkg = tab.pkgController.text.trim();
    tab.packageFilter = pkg;
    sendCommand(
      FilterCommand(pkg.isEmpty ? null : pkg, serial: _effectiveSerialFor(tab)),
    );
    _recomputeTab(tab);
    _persistTabs();
  }

  void applyPackage() => applyPackageForTab(activeTabId);

  void setFilterPackageForTab(String tabId, String pkg) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    tab.packageFilter = pkg;
    applyPackageForTab(tabId);
  }

  void setFilterPackage(String pkg) => setFilterPackageForTab(activeTabId, pkg);

  void setFilterTagForTab(String tabId, String tag) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    tab.search = tag;
    _recomputeTab(tab);
    _persistTabs();
  }

  void setFilterTag(String tag) => setFilterTagForTab(activeTabId, tag);

  /// Clears logs for [tabId] by default. Pass [clearDeviceBuffer] as `true`
  /// to run `adb logcat -c` on the bridge for that tab's device.
  void clearLogsForTab(String tabId, {bool clearDeviceBuffer = false}) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    if (clearDeviceBuffer) {
      sendCommand(ClearCommand(serial: _effectiveSerialFor(tab)));
      return;
    }
    if (tab.lines.isNotEmpty) {
      tab.clearedAfterSeq = tab.lines.last.seq;
    }
    if (tab.paused) {
      tab.pausedBufferSnapshot = [];
      tab.lines.clear();
    }
    _recomputeTab(tab);
  }

  void clearLogs({bool clearDeviceBuffer = false}) =>
      clearLogsForTab(activeTabId, clearDeviceBuffer: clearDeviceBuffer);

  void restartAdbForTab(String tabId) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    sendCommand(RestartCommand(serial: _effectiveSerialFor(tab)));
  }

  void restartAdb() => restartAdbForTab(activeTabId);

  void applyDevice(String? serial) => setTabDeviceForTab(activeTabId, serial);

  void updateColumns(LogColumnConfig next) {
    _columns = next;
    saveColumnConfig(next);
    notifyListeners();
  }

  Future<void> savePresetForTab(String tabId, String name) async {
    final tab = _tabByIdOrNull(tabId) ?? activeTab;
    final preset = FilterPreset(
      name: name,
      package: tab.pkgController.text.trim(),
      search: tab.searchController.text,
      minLevel: tab.minLevel,
      useRegex: tab.useRegex,
    );
    final next = [..._presets.where((p) => p.name != name), preset];
    _presets = next;
    notifyListeners();
    await saveFilterPresets(next);
  }

  Future<void> savePreset(String name) => savePresetForTab(activeTabId, name);

  Future<void> deletePreset(FilterPreset preset) async {
    final next = _presets.where((p) => p.name != preset.name).toList();
    _presets = next;
    notifyListeners();
    await saveFilterPresets(next);
  }

  void applyPresetForTab(String tabId, FilterPreset preset) {
    final tab = _tabByIdOrNull(tabId);
    if (tab == null) return;
    tab.packageFilter = preset.package;
    tab.search = preset.search;
    tab.minLevel = preset.minLevel;
    tab.useRegex = preset.useRegex;
    applyPackageForTab(tabId);
  }

  void applyPreset(FilterPreset preset) =>
      applyPresetForTab(activeTabId, preset);

  String _formatEntry(LogEntry e, String currentPkg, int? currentAppPid) {
    final parts = <String>[];
    if (_columns.showTime) parts.add(e.time);
    if (_columns.showPidTid) parts.add('${e.pid}-${e.tid}');
    if (_columns.showPackage) {
      final pkg =
          e.pkg ??
          (currentAppPid != null && e.pid == currentAppPid ? currentPkg : null);
      if (pkg != null && pkg.isNotEmpty) parts.add(pkg);
    }
    if (_columns.showLevel && _columns.showTag) {
      parts.add('${e.level}/${e.tag}:');
    } else {
      if (_columns.showLevel) parts.add('[${e.level}]');
      if (_columns.showTag) parts.add('${e.tag}:');
    }
    parts.add(e.msg);
    return parts.join(' ');
  }

  Future<String> exportLogsForTab(String tabId) async {
    final tab = _tabByIdOrNull(tabId) ?? activeTab;
    final buf = StringBuffer();
    final currentPkg = tab.pkgController.text.trim();
    final pid = appPidForTab(tab);
    for (final e in tab.visible) {
      buf.writeln(_formatEntry(e, currentPkg, pid));
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final filename = 'logcat_$stamp.log';

    return exportLog(buf.toString(), filename);
  }

  Future<String> exportLogs() => exportLogsForTab(activeTabId);

  void copyLogEntry(LogEntry e, {LogTabState? tab}) {
    final t = tab ?? activeTab;
    Clipboard.setData(
      ClipboardData(
        text: _formatEntry(e, t.pkgController.text.trim(), appPidForTab(t)),
      ),
    );
  }

  @override
  void dispose() {
    _deviceController.removeListener(_onDeviceChanged);
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _reconnect?.cancel();
    for (final timer in _searchDebounces.values) {
      timer.cancel();
    }
    _searchDebounces.clear();
    _sub?.cancel();
    _channel?.sink.close();
    for (final tab in _tabs) {
      final listener = _scrollListeners.remove(tab.id);
      if (listener != null && !tab.isDisposed) {
        tab.scrollController.removeListener(listener);
      }
      tab.dispose();
    }
    _emptyVisibleNotifier.dispose();
    _emptyStatsNotifier.dispose();
    _dummyScrollController.dispose();
    stopBridge();
    super.dispose();
  }
}
