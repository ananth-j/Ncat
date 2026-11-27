import 'dart:async';
import 'dart:collection';
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

/// Isolated per-pane buffer, filtered list, notifiers, and scroll controller.
class _LogPaneSlot {
  final List<LogEntry> lines = [];
  final List<LogEntry> visible = [];
  final ValueNotifier<List<LogEntry>> visibleNotifier =
      ValueNotifier<List<LogEntry>>([]);
  final ValueNotifier<LogStats> statsNotifier = ValueNotifier<LogStats>((
    total: 0,
    visible: 0,
    hiddenNoise: 0,
  ));
  final ScrollController scrollController = ScrollController();

  int hiddenNoiseCount = 0;
  int cachedMinRank = 0;
  LogQuery cachedQuery = LogQuery('');

  void dispose() {
    scrollController.dispose();
    visibleNotifier.dispose();
    statsNotifier.dispose();
  }
}

/// Central state controller for logcat streaming, multi-tab filtering, split panes, presets, and export.
class LogcatController extends ChangeNotifier with WidgetsBindingObserver {
  LogcatController({
    int maxLines = kMaxLines,
    DeviceController? deviceController,
  }) : _maxLines = maxLines,
       _deviceController = deviceController ?? DeviceController() {
    _deviceController.addListener(_onDeviceChanged);
  }

  final int _maxLines;
  final DeviceController _deviceController;

  void _onDeviceChanged() {
    notifyListeners();
  }

  final _LogPaneSlot _pane0 = _LogPaneSlot();
  final _LogPaneSlot _pane1 = _LogPaneSlot();
  int _focusedPane = 0;
  LogSplitAxis _splitAxis = LogSplitAxis.none;
  double _splitRatio = 0.5;
  String _pane0TabId = 'tab_1';
  String? _pane1TabId;

  _LogPaneSlot get _focusedSlot => _focusedPane == 1 && isSplit ? _pane1 : _pane0;

  /// Dedicated [ValueNotifier] for the primary pane's visible list.
  ValueNotifier<List<LogEntry>> get visibleNotifier => _pane0.visibleNotifier;

  /// Publishes aggregate line counts for the primary pane.
  ValueNotifier<LogStats> get statsNotifier => _pane0.statsNotifier;

  ScrollController get scrollController => _pane0.scrollController;

  // Explicit primary & secondary pane accessors for split view rendering
  ValueNotifier<List<LogEntry>> get primaryVisibleNotifier =>
      _pane0.visibleNotifier;
  ValueNotifier<LogStats> get primaryStatsNotifier => _pane0.statsNotifier;
  ScrollController get primaryScrollController => _pane0.scrollController;
  List<LogEntry> get primaryLines => _pane0.lines;
  List<LogEntry> get primaryVisible => _pane0.visible;

  ValueNotifier<List<LogEntry>> get secondaryVisibleNotifier =>
      _pane1.visibleNotifier;
  ValueNotifier<LogStats> get secondaryStatsNotifier => _pane1.statsNotifier;
  ScrollController get secondaryScrollController => _pane1.scrollController;
  List<LogEntry> get secondaryLines => _pane1.lines;
  List<LogEntry> get secondaryVisible => _pane1.visible;

  final TextEditingController searchController = TextEditingController();
  final TextEditingController pkgController = TextEditingController();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;
  Timer? _searchDebounce;

  String _connection = 'connecting';
  String _serverStatus = '';
  int? _appPid;
  String? _lastStatusPackage;

  // Multi-tab state (Android Studio Logcat-style)
  final List<LogTabState> _tabs = [
    LogTabState(id: 'tab_1', title: 'Logcat 1'),
  ];
  String _activeTabId = 'tab_1';
  int _nextTabCounter = 2;
  bool _userModifiedTabs = false;

  DeviceTabState _getOrCreateDeviceBuffer(String serial) =>
      _deviceController.getOrCreateTab(serial);

  List<FilterPreset> _presets = const [];

  String _search = '';
  String _minLevel = 'V';
  bool _paused = false;
  bool _wrap = true;
  bool _autoScroll = true;
  bool _useRegex = false;
  NoiseFilterMode _noiseMode = NoiseFilterMode.reduce;

  // Background mode tracking (Phase 2.4)
  bool _isAppActive = true;
  bool _needsUiSync = false;

  LogColumnConfig _columns = const LogColumnConfig();

  // Getters
  int get maxLines => _maxLines;
  List<LogEntry> get lines => _focusedSlot.lines;
  List<LogEntry> get visible => _focusedSlot.visible;
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
  String get search => _search;
  String get minLevel => _minLevel;
  bool get paused => _paused;
  bool get wrap => _wrap;
  bool get autoScroll => _autoScroll;
  bool get useRegex => _useRegex;
  NoiseFilterMode get noiseMode => _noiseMode;
  bool get reduceNoise => _noiseMode == NoiseFilterMode.reduce;
  int get hiddenNoiseCount => _focusedSlot.hiddenNoiseCount;
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

  void init() {
    WidgetsBinding.instance.addObserver(this);
    _pane0.scrollController.addListener(() => _onPaneScroll(0));
    _pane1.scrollController.addListener(() => _onPaneScroll(1));
    _updateFilterCache(_pane0, primaryTab);

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
        _tabs
          ..clear()
          ..addAll(saved.tabs);
        final targetId =
            saved.activeTabId != null &&
                    _tabs.any((t) => t.id == saved.activeTabId)
                ? saved.activeTabId!
                : _tabs.first.id;
        _pane0TabId = targetId;
        _activeTabId = targetId;
        _focusedPane = 0;
        _nextTabCounter = _computeNextTabCounter(_tabs);
        _loadTabFields(activeTab);
        _syncPaneLinesFromBuffer(0);
        _recomputePane(0);
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
        _recomputeAllPanes();
      }
    }
  }

  void _onPaneScroll(int paneIndex) {
    final slot = paneIndex == 1 ? _pane1 : _pane0;
    final tab = paneIndex == 1 ? secondaryTab : primaryTab;
    if (tab == null || !slot.scrollController.hasClients) return;

    final max = slot.scrollController.position.maxScrollExtent;
    final current = slot.scrollController.offset;
    final atBottom = max <= 0 || current >= (max - 50);

    if (atBottom && !tab.autoScroll) {
      tab.autoScroll = true;
      if (paneIndex == _focusedPane) _autoScroll = true;
      notifyListeners();
    } else if (!atBottom && tab.autoScroll) {
      tab.autoScroll = false;
      tab.scrollOffset = current;
      if (paneIndex == _focusedPane) _autoScroll = false;
      notifyListeners();
    } else if (!tab.autoScroll) {
      tab.scrollOffset = current;
    }
  }

  static const double _rowExtent = 23.0;

  void scrollToBottom([int? paneIndex]) {
    final idx = paneIndex ?? _focusedPane;
    final slot = idx == 1 && isSplit ? _pane1 : _pane0;
    final tab = idx == 1 && isSplit ? secondaryTab! : primaryTab;
    if (!_isAppActive || !slot.scrollController.hasClients) return;

    if (!tab.wrap && slot.visible.isNotEmpty) {
      final viewportHeight = slot.scrollController.position.viewportDimension;
      final totalHeight = slot.visible.length * _rowExtent;
      final target = (totalHeight - viewportHeight).clamp(
        0.0,
        double.infinity,
      );
      slot.scrollController.jumpTo(target);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (tab.autoScroll && slot.scrollController.hasClients) {
          slot.scrollController.jumpTo(
            slot.scrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }

  void scrollToEnd([int? paneIndex]) {
    final idx = paneIndex ?? _focusedPane;
    final tab = idx == 1 && isSplit ? secondaryTab! : primaryTab;
    scrollToBottom(idx);
    tab.autoScroll = true;
    if (idx == _focusedPane) {
      _autoScroll = true;
    }
    notifyListeners();
  }

  void scrollToTop([int? paneIndex]) {
    final idx = paneIndex ?? _focusedPane;
    final slot = idx == 1 && isSplit ? _pane1 : _pane0;
    final tab = idx == 1 && isSplit ? secondaryTab! : primaryTab;
    tab.autoScroll = false;
    tab.scrollOffset = 0.0;
    if (idx == _focusedPane) {
      _autoScroll = false;
    }
    notifyListeners();
    if (slot.scrollController.hasClients) {
      slot.scrollController.jumpTo(0);
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
        final targetSerial = serial ?? _deviceController.activeDevice;
        if (targetSerial != null) {
          final devBuf = _getOrCreateDeviceBuffer(targetSerial);
          devBuf.lines
            ..clear()
            ..addAll(lines);
        }
        _applyHistoryToPane(0, primaryTab, lines, targetSerial);
        if (isSplit) {
          _applyHistoryToPane(1, secondaryTab!, lines, targetSerial);
        }
        break;

      case LogBatchMessage(:final lines, :final serial):
        final targetSerial = serial ?? _deviceController.activeDevice;
        if (targetSerial == null) {
          if (_paused && !isSplit) return;
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

        _applyBatchToPane(0, primaryTab, lines, targetSerial);
        if (isSplit) {
          _applyBatchToPane(1, secondaryTab!, lines, targetSerial);
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

        _clearPaneIfMatches(0, primaryTab, targetSerial);
        if (isSplit) {
          _clearPaneIfMatches(1, secondaryTab!, targetSerial);
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

  void _applyHistoryToPane(
    int paneIndex,
    LogTabState tab,
    List<LogEntry> lines,
    String? targetSerial,
  ) {
    final paneSerial = _effectiveSerialFor(tab);
    if (targetSerial != null &&
        paneSerial != null &&
        targetSerial != paneSerial) {
      return;
    }
    if (tab.paused) return;

    final slot = paneIndex == 1 ? _pane1 : _pane0;
    slot.lines
      ..clear()
      ..addAll(lines);
    _recomputePane(paneIndex, notifyController: paneIndex == _focusedPane);
    if (tab.autoScroll) {
      scrollToBottom(paneIndex);
    }
  }

  void _applyBatchToPane(
    int paneIndex,
    LogTabState tab,
    List<LogEntry> lines,
    String? targetSerial,
  ) {
    final paneSerial = _effectiveSerialFor(tab);
    if (targetSerial != null &&
        paneSerial != null &&
        targetSerial != paneSerial) {
      return;
    }
    if (tab.paused) return;

    final slot = paneIndex == 1 ? _pane1 : _pane0;
    slot.lines.addAll(lines);
    final maxCapacity = tab.autoScroll ? _maxLines : _maxLines * 2;
    final excess = slot.lines.length - maxCapacity;
    if (excess > 0) {
      slot.lines.removeRange(0, excess);
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
        slot.cachedQuery.hasNoiseTerm;
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
        slot: slot,
        currentPkg: currentPkg,
        tabAppPid: currentAppPid,
        isNoise: isNoise,
      )) {
        passing.add(l);
      } else if (isReduced && isNoise) {
        slot.hiddenNoiseCount++;
      }
    }
    if (excess > 0 && slot.hiddenNoiseCount > slot.lines.length) {
      slot.hiddenNoiseCount = (slot.lines.length - slot.visible.length).clamp(
        0,
        slot.lines.length,
      );
    }
    if (excess > 0) {
      _trimVisibleToBufferStart(slot);
    }
    if (passing.isNotEmpty) {
      slot.visible.addAll(passing);
    }

    _publishPaneVisibleAndStats(slot);
    if (tab.autoScroll) {
      scrollToBottom(paneIndex);
    }
  }

  void _clearPaneIfMatches(
    int paneIndex,
    LogTabState tab,
    String? targetSerial,
  ) {
    final paneSerial = _effectiveSerialFor(tab);
    if (targetSerial == null ||
        paneSerial == null ||
        targetSerial == paneSerial) {
      final slot = paneIndex == 1 ? _pane1 : _pane0;
      slot.lines.clear();
      slot.hiddenNoiseCount = 0;
      _recomputePane(paneIndex, notifyController: paneIndex == _focusedPane);
    }
  }

  // ---------------------------------------------------------------------------
  // Multi-tab & split-pane management
  // ---------------------------------------------------------------------------

  void _saveActiveTabFields() {
    final tab = activeTab;
    tab.search = _search;
    tab.minLevel = _minLevel;
    tab.packageFilter = pkgController.text.trim();
    tab.useRegex = _useRegex;
    tab.autoScroll = _autoScroll;
    tab.paused = _paused;
    tab.wrap = _wrap;
    tab.noiseMode = _noiseMode;
    final slot = _focusedSlot;
    if (slot.scrollController.hasClients) {
      tab.scrollOffset = slot.scrollController.offset;
    }
  }

  void _loadTabFields(LogTabState tab) {
    _search = tab.search;
    searchController.text = tab.search;
    pkgController.text = tab.packageFilter;
    _minLevel = tab.minLevel;
    _useRegex = tab.useRegex;
    _autoScroll = tab.autoScroll;
    _paused = tab.paused;
    _wrap = tab.wrap;
    _noiseMode = tab.noiseMode;
  }

  void _syncPaneLinesFromBuffer(int paneIndex) {
    final tab = paneIndex == 1 ? secondaryTab : primaryTab;
    if (tab == null) return;
    final slot = paneIndex == 1 ? _pane1 : _pane0;

    if (tab.paused && tab.pausedBufferSnapshot != null) {
      slot.lines
        ..clear()
        ..addAll(tab.pausedBufferSnapshot!);
      return;
    }
    final serial = _effectiveSerialFor(tab);
    if (serial != null) {
      final devBuf = _getOrCreateDeviceBuffer(serial);
      slot.lines
        ..clear()
        ..addAll(devBuf.lines);
    }
  }

  void _persistTabs() {
    unawaited(saveLogTabs(_tabs, _activeTabId));
  }

  /// Adds a new log tab (optionally targeting [deviceSerial], applying a
  /// [preset], or duplicating the active tab) and opens it in the focused pane.
  String addTab({
    String? deviceSerial,
    FilterPreset? preset,
    bool duplicateCurrent = false,
    String? title,
  }) {
    _saveActiveTabFields();
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

  /// Reorders a tab in the tab strip from its current index to [newIndex].
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

  /// Splits the viewport along [axis] to show two tabs simultaneously.
  ///
  /// When [tabId] matches the current pane tab and only one tab exists, a
  /// duplicate tab is created automatically for the second pane.
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

    _saveActiveTabFields();
    _userModifiedTabs = true;

    if (putInPrimary) {
      final previousPrimary = _pane0TabId;
      String secondId;
      if (previousPrimary != tabId) {
        secondId = previousPrimary;
      } else {
        secondId = _findOrCreateSiblingTabId(tabId);
      }
      _pane0TabId = tabId;
      _pane1TabId = secondId;
      _splitAxis = axis;
      _focusedPane = 0;
      _activeTabId = tabId;
    } else {
      String secondId = tabId;
      if (secondId == _pane0TabId) {
        secondId = _findOrCreateSiblingTabId(tabId);
      }
      _pane1TabId = secondId;
      _splitAxis = axis;
      _focusedPane = 1;
      _activeTabId = secondId;
    }

    _loadTabFields(activeTab);
    _syncPaneLinesFromBuffer(0);
    _syncPaneLinesFromBuffer(1);
    _recomputeAllPanes();
    _persistTabs();
  }

  String _findOrCreateSiblingTabId(String excludeTabId) {
    for (final t in _tabs) {
      if (t.id != excludeTabId) return t.id;
    }
    final num = _nextTabCounter++;
    final id = 'tab_$num';
    final base = _tabById(excludeTabId);
    _tabs.add(
      base.copyWith(
        id: id,
        title: 'Logcat $num',
        isCustomTitle: false,
        paused: false,
      ),
    );
    return id;
  }

  /// Toggles side-by-side split view on or off.
  void toggleSplit([LogSplitAxis axis = LogSplitAxis.horizontal]) {
    if (isSplit) {
      closeSplit();
    } else {
      splitWithTab(activeTabId, axis);
    }
  }

  /// Closes the secondary split pane while keeping the focused tab open.
  void closeSplit() {
    if (!isSplit) return;
    _saveActiveTabFields();
    if (_focusedPane == 1 && _pane1TabId != null) {
      _pane0TabId = _pane1TabId!;
    }
    _pane1TabId = null;
    _splitAxis = LogSplitAxis.none;
    _focusedPane = 0;
    _activeTabId = _pane0TabId;
    _loadTabFields(activeTab);
    _syncPaneLinesFromBuffer(0);
    _recomputePane(0);
    _persistTabs();
  }

  void setSplitRatio(double ratio) {
    final clamped = ratio.clamp(0.2, 0.8);
    if ((_splitRatio - clamped).abs() < 0.001) return;
    _splitRatio = clamped;
    notifyListeners();
  }

  /// Focuses pane [paneIndex] (`0` = primary, `1` = secondary) so toolbars and
  /// filters bind to that pane's tab.
  void focusPane(int paneIndex) {
    if (!isSplit) return;
    if (paneIndex != 0 && paneIndex != 1) return;
    if (_focusedPane == paneIndex) return;

    _saveActiveTabFields();
    _focusedPane = paneIndex;
    _activeTabId = paneIndex == 1 ? _pane1TabId! : _pane0TabId;
    _loadTabFields(activeTab);

    final nextSerial = activeTabSerial;
    if (nextSerial != null && nextSerial != _deviceController.activeDevice) {
      _deviceController.setActiveDevice(nextSerial);
      sendCommand(DeviceCommand(nextSerial));
    }
    notifyListeners();
  }

  /// Switches the focused pane to [tabId], or moves focus if [tabId] is already
  /// shown in the other split pane.
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
    _saveActiveTabFields();

    final prevSerial = activeTabSerial;
    _activeTabId = tabId;
    if (_focusedPane == 1 && isSplit) {
      _pane1TabId = tabId;
    } else {
      _pane0TabId = tabId;
    }
    _loadTabFields(target);

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

    final paneIdx = _focusedPane == 1 && isSplit ? 1 : 0;
    _syncPaneLinesFromBuffer(paneIdx);
    _recomputePane(paneIdx);

    if (_autoScroll) {
      scrollToBottom(paneIdx);
    } else {
      final offset = target.scrollOffset;
      final slot = paneIdx == 1 ? _pane1 : _pane0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (slot.scrollController.hasClients) {
          final max = slot.scrollController.position.maxScrollExtent;
          slot.scrollController.jumpTo(offset.clamp(0.0, max));
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

  /// Closes [tabId] while always keeping at least one open tab.
  void closeTab(String tabId) {
    if (_tabs.length <= 1) return;
    final idx = _tabs.indexWhere((t) => t.id == tabId);
    if (idx < 0) return;

    _userModifiedTabs = true;

    if (isSplit) {
      if (_pane1TabId == tabId) {
        _tabs.removeAt(idx);
        _pane1TabId = null;
        _splitAxis = LogSplitAxis.none;
        _focusedPane = 0;
        _activeTabId = _pane0TabId;
        _loadTabFields(activeTab);
        _syncPaneLinesFromBuffer(0);
        _recomputePane(0);
        _persistTabs();
        return;
      }
      if (_pane0TabId == tabId) {
        _tabs.removeAt(idx);
        _pane0TabId = _pane1TabId!;
        _pane1TabId = null;
        _splitAxis = LogSplitAxis.none;
        _focusedPane = 0;
        _activeTabId = _pane0TabId;
        _loadTabFields(activeTab);
        _syncPaneLinesFromBuffer(0);
        _recomputePane(0);
        _persistTabs();
        return;
      }
    }

    if (_activeTabId == tabId) {
      final fallbackIdx = idx > 0 ? idx - 1 : 1;
      selectTab(_tabs[fallbackIdx].id);
    }
    _tabs.removeWhere((t) => t.id == tabId);
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
    _tabs.removeWhere((t) => t.id != tabId);
    _persistTabs();
    notifyListeners();
  }

  void closeTabsToRight(String tabId) {
    final idx = _tabs.indexWhere((t) => t.id == tabId);
    if (idx < 0 || idx >= _tabs.length - 1) return;
    _userModifiedTabs = true;
    final activeIdx = activeTabIndex;
    if (activeIdx > idx) {
      selectTab(tabId);
    }
    _tabs.removeRange(idx + 1, _tabs.length);
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

  /// Changes the target device serial for the currently focused tab.
  void setTabDevice(String? serial) {
    _userModifiedTabs = true;
    final normalized = (serial == null || serial.isEmpty) ? null : serial;
    final current = activeTab;
    current.deviceSerial = normalized;
    current.clearedAfterSeq = null;
    current.pausedBufferSnapshot = null;

    _deviceController.applyDevice(normalized);
    final effective = activeTabSerial;
    if (effective != null) {
      sendCommand(DeviceCommand(effective));
    } else {
      sendCommand(const DeviceCommand(null));
    }

    final paneIdx = _focusedPane == 1 && isSplit ? 1 : 0;
    _syncPaneLinesFromBuffer(paneIdx);
    _recomputePane(paneIdx);
    _persistTabs();
  }

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
        _focusedSlot.lines.isEmpty &&
        _search.isEmpty &&
        pkgController.text.trim().isEmpty;
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

  void _updateFilterCache(_LogPaneSlot slot, LogTabState tab) {
    slot.cachedMinRank = switch (tab.minLevel) {
      'V' => 0,
      'D' => 1,
      'I' => 2,
      'W' => 3,
      'E' => 4,
      'F' || 'S' => 5,
      _ => kLevels.indexOf(tab.minLevel).clamp(0, kLevels.length - 1),
    };
    slot.cachedQuery = LogQuery(tab.search, useRegex: tab.useRegex);
  }

  void _trimVisibleToBufferStart(_LogPaneSlot slot) {
    if (slot.visible.isEmpty || slot.lines.isEmpty) return;
    final minSeq = slot.lines.first.seq;
    var trimCount = 0;
    while (trimCount < slot.visible.length &&
        slot.visible[trimCount].seq < minSeq) {
      trimCount++;
    }
    if (trimCount > 0) {
      slot.visible.removeRange(0, trimCount);
    }
  }

  void _publishPaneVisibleAndStats(_LogPaneSlot slot) {
    slot.visibleNotifier.value = UnmodifiableListView<LogEntry>(slot.visible);
    slot.statsNotifier.value = (
      total: slot.lines.length,
      visible: slot.visible.length,
      hiddenNoise: slot.hiddenNoiseCount,
    );
  }

  bool _matchesEntry(
    LogEntry e, {
    required LogTabState tab,
    required _LogPaneSlot slot,
    required String currentPkg,
    required int? tabAppPid,
    required bool isNoise,
  }) {
    if (e.rank < slot.cachedMinRank) return false;

    if (currentPkg.isNotEmpty) {
      final lowerPkg = currentPkg.toLowerCase();
      final entryPkg = e.pkg?.toLowerCase();
      final matchesPkg = entryPkg != null && entryPkg.contains(lowerPkg);
      final matchesPid = tabAppPid != null && e.pid == tabAppPid;
      if (!matchesPkg && !matchesPid) return false;
    }

    if (!slot.cachedQuery.hasNoiseTerm) {
      if (tab.noiseMode == NoiseFilterMode.reduce && isNoise) {
        return false;
      } else if (tab.noiseMode == NoiseFilterMode.onlyNoise && !isNoise) {
        return false;
      }
    }

    for (final term in slot.cachedQuery.terms) {
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

  void _recompute() {
    _recomputePane(_focusedPane == 1 && isSplit ? 1 : 0);
  }

  void _recomputeAllPanes() {
    _recomputePane(0, notifyController: false);
    if (isSplit) {
      _recomputePane(1, notifyController: false);
    }
    notifyListeners();
  }

  void _recomputePane(int paneIndex, {bool notifyController = true}) {
    final tab = paneIndex == 1 ? secondaryTab : primaryTab;
    if (tab == null) return;
    final slot = paneIndex == 1 ? _pane1 : _pane0;

    _updateFilterCache(slot, tab);
    slot.visible.clear();
    int hidden = 0;
    final isReduced = tab.noiseMode == NoiseFilterMode.reduce;
    final needsNoiseCheck =
        isReduced ||
        tab.noiseMode == NoiseFilterMode.onlyNoise ||
        slot.cachedQuery.hasNoiseTerm;
    final currentPkg = tab.packageFilter.trim();
    final currentAppPid = appPidForTab(tab);
    final clearedAfter = tab.clearedAfterSeq;

    for (final e in slot.lines) {
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
        slot: slot,
        currentPkg: currentPkg,
        tabAppPid: currentAppPid,
        isNoise: isNoise,
      )) {
        slot.visible.add(e);
      } else if (isReduced && isNoise) {
        hidden++;
      }
    }
    slot.hiddenNoiseCount = hidden;
    _publishPaneVisibleAndStats(slot);
    if (notifyController) {
      notifyListeners();
    }
  }

  // User Actions (scoped to the active/focused tab)
  void setNoiseMode(NoiseFilterMode mode) {
    if (_noiseMode == mode) return;
    _noiseMode = mode;
    activeTab.noiseMode = mode;
    _recompute();
    _persistTabs();
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
    activeTab.search = v;
    if (immediate) {
      _searchDebounce?.cancel();
      _recompute();
      _persistTabs();
    } else {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 150), () {
        _recompute();
        _persistTabs();
      });
    }
  }

  void setMinLevel(String v) {
    _minLevel = v;
    activeTab.minLevel = v;
    _recompute();
    _persistTabs();
  }

  void toggleRegex() {
    _useRegex = !_useRegex;
    activeTab.useRegex = _useRegex;
    _recompute();
    _persistTabs();
  }

  void togglePaused() {
    _paused = !_paused;
    activeTab.paused = _paused;
    final paneIdx = _focusedPane == 1 && isSplit ? 1 : 0;
    final slot = _focusedSlot;
    if (_paused) {
      activeTab.pausedBufferSnapshot = List<LogEntry>.of(slot.lines);
    } else {
      activeTab.pausedBufferSnapshot = null;
      _syncPaneLinesFromBuffer(paneIdx);
      _recomputePane(paneIdx);
      return;
    }
    notifyListeners();
  }

  void toggleWrap() {
    _wrap = !_wrap;
    activeTab.wrap = _wrap;
    notifyListeners();
    _persistTabs();
  }

  void applyPackage() {
    final pkg = pkgController.text.trim();
    activeTab.packageFilter = pkg;
    sendCommand(
      FilterCommand(pkg.isEmpty ? null : pkg, serial: activeTabSerial),
    );
    _recompute();
    _persistTabs();
  }

  void setFilterPackage(String pkg) {
    pkgController.text = pkg;
    applyPackage();
  }

  void setFilterTag(String tag) {
    searchController.text = tag;
    _search = tag;
    activeTab.search = tag;
    _recompute();
    _persistTabs();
  }

  /// Clears logs for the active tab view by default. Pass [clearDeviceBuffer]
  /// as `true` to also run `adb logcat -c` on the bridge for the active device.
  void clearLogs({bool clearDeviceBuffer = false}) {
    if (clearDeviceBuffer) {
      sendCommand(ClearCommand(serial: activeTabSerial));
      return;
    }
    final slot = _focusedSlot;
    if (slot.lines.isNotEmpty) {
      activeTab.clearedAfterSeq = slot.lines.last.seq;
    }
    if (activeTab.paused) {
      activeTab.pausedBufferSnapshot = [];
      slot.lines.clear();
    }
    _recompute();
  }

  void restartAdb() {
    sendCommand(RestartCommand(serial: activeTabSerial));
  }

  void applyDevice(String? serial) {
    setTabDevice(serial);
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
    activeTab.packageFilter = preset.package;
    activeTab.search = preset.search;
    activeTab.minLevel = preset.minLevel;
    activeTab.useRegex = preset.useRegex;
    applyPackage();
  }

  String _formatEntry(LogEntry e, String currentPkg, [int? currentAppPid]) {
    final parts = <String>[];
    final pidVal = currentAppPid ?? appPid;
    if (_columns.showTime) parts.add(e.time);
    if (_columns.showPidTid) parts.add('${e.pid}-${e.tid}');
    if (_columns.showPackage) {
      final pkg =
          e.pkg ?? (pidVal != null && e.pid == pidVal ? currentPkg : null);
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

  Future<String> exportLogs() async {
    final buf = StringBuffer();
    final currentPkg = pkgController.text.trim();
    for (final e in _focusedSlot.visible) {
      buf.writeln(_formatEntry(e, currentPkg));
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final filename = 'logcat_$stamp.log';

    return exportLog(buf.toString(), filename);
  }

  void copyLogEntry(LogEntry e, {LogTabState? tab}) {
    final t = tab ?? activeTab;
    Clipboard.setData(
      ClipboardData(
        text: _formatEntry(e, t.packageFilter.trim(), appPidForTab(t)),
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
    _searchDebounce?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _pane0.dispose();
    _pane1.dispose();
    searchController.dispose();
    pkgController.dispose();
    stopBridge();
    super.dispose();
  }
}
