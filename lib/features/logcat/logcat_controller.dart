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

/// Central state controller for logcat streaming, multi-tab filtering, presets, and export.
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

  /// Publishes aggregate line counts independently of [ChangeNotifier] so
  /// incoming log batches update the status bar without rebuilding toolbars.
  final ValueNotifier<LogStats> statsNotifier = ValueNotifier<LogStats>((
    total: 0,
    visible: 0,
    hiddenNoise: 0,
  ));

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

  /// Effective PID for the active tab's package filter on its target device.
  int? get appPid {
    final pkg = pkgController.text.trim();
    final serial = activeTabSerial;
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
  int get hiddenNoiseCount => _hiddenNoiseCount;
  LogColumnConfig get columns => _columns;

  // Multi-tab getters
  List<LogTabState> get logTabs => List.unmodifiable(_tabs);
  String get activeTabId => _activeTabId;
  LogTabState get activeTab => _tabs.firstWhere(
    (t) => t.id == _activeTabId,
    orElse: () => _tabs.first,
  );
  int get activeTabIndex =>
      _tabs.indexWhere((t) => t.id == activeTab.id).clamp(0, _tabs.length - 1);
  String? get activeTabSerial =>
      activeTab.deviceSerial ?? _deviceController.activeDevice;

  String? _effectiveSerialFor(LogTabState tab) =>
      tab.deviceSerial ?? _deviceController.activeDevice;

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
        _activeTabId = targetId;
        _nextTabCounter = _computeNextTabCounter(_tabs);
        _loadTabFields(activeTab);
        _syncLinesFromActiveBuffer();
        _recompute();
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
      activeTab.autoScroll = true;
      notifyListeners();
    } else if (!atBottom && _autoScroll) {
      _autoScroll = false;
      activeTab.autoScroll = false;
      activeTab.scrollOffset = current;
      notifyListeners();
    } else if (!_autoScroll) {
      activeTab.scrollOffset = current;
    }
  }

  /// Fixed row height used by [ListView.builder] when wrap is off.
  /// Must stay in sync with the [itemExtent] value in [LogTableView._logList].
  static const double _rowExtent = 23.0;

  /// Jumps the scroll position to the bottom of the list.
  void scrollToBottom() {
    if (!_isAppActive || !scrollController.hasClients) return;

    if (!_wrap && _visible.isNotEmpty) {
      final viewportHeight = scrollController.position.viewportDimension;
      final totalHeight = _visible.length * _rowExtent;
      final target = (totalHeight - viewportHeight).clamp(
        0.0,
        double.infinity,
      );
      scrollController.jumpTo(target);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_autoScroll && scrollController.hasClients) {
          scrollController.jumpTo(scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  void scrollToEnd() {
    scrollToBottom();
    _autoScroll = true;
    activeTab.autoScroll = true;
    notifyListeners();
  }

  void scrollToTop() {
    _autoScroll = false;
    activeTab.autoScroll = false;
    activeTab.scrollOffset = 0.0;
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
        final targetSerial = serial ?? _deviceController.activeDevice;
        if (targetSerial != null) {
          final devBuf = _getOrCreateDeviceBuffer(targetSerial);
          devBuf.lines
            ..clear()
            ..addAll(lines);
        }
        final currentSerial = activeTabSerial;
        if (targetSerial == null ||
            currentSerial == null ||
            targetSerial == currentSerial) {
          if (!activeTab.paused) {
            _lines
              ..clear()
              ..addAll(lines);
            _recompute();
            if (_autoScroll) {
              scrollToBottom();
            }
          }
        }
        break;

      case LogBatchMessage(:final lines, :final serial):
        final targetSerial = serial ?? _deviceController.activeDevice;
        if (targetSerial == null) {
          if (_paused) return;
        } else {
          // Only drop incoming lines if ALL tabs targeting this device are paused.
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

        // If batch belongs to a background device, keep it buffered without rebuilding UI.
        final currentSerial = activeTabSerial;
        if (targetSerial != null &&
            currentSerial != null &&
            targetSerial != currentSerial) {
          return;
        }

        // If the active tab is paused while a sibling tab on the same device is live,
        // leave the active tab's frozen snapshot untouched.
        if (_paused) return;

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

        // Phase 2.2: Incremental filtering - evaluate each newly arrived line once
        final currentPkg = pkgController.text.trim();
        final currentAppPid = appPid;
        final isReduced = _noiseMode == NoiseFilterMode.reduce;
        final needsNoiseCheck =
            isReduced ||
            _noiseMode == NoiseFilterMode.onlyNoise ||
            _cachedQuery.hasNoiseTerm;
        final clearedAfter = activeTab.clearedAfterSeq;
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
            currentPkg: currentPkg,
            tabAppPid: currentAppPid,
            isNoise: isNoise,
          )) {
            passing.add(l);
          } else if (isReduced && isNoise) {
            _hiddenNoiseCount++;
          }
        }
        if (excess > 0 && _hiddenNoiseCount > _lines.length) {
          _hiddenNoiseCount = (_lines.length - _visible.length).clamp(
            0,
            _lines.length,
          );
        }
        if (excess > 0) {
          _trimVisibleToBufferStart();
        }
        if (passing.isNotEmpty) {
          _visible.addAll(passing);
        }

        // Phase 2.1: Publish via targeted ValueNotifiers only so incoming log
        // batches rebuild the list and status bar without rebuilding toolbars.
        _publishVisibleAndStats();
        if (_autoScroll) {
          scrollToBottom();
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
        final currentSerial = activeTabSerial;
        if (targetSerial == null ||
            currentSerial == null ||
            targetSerial == currentSerial) {
          _lines.clear();
          _hiddenNoiseCount = 0;
          _recompute();
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

  // ---------------------------------------------------------------------------
  // Multi-tab management (single or multiple devices)
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
    if (scrollController.hasClients) {
      tab.scrollOffset = scrollController.offset;
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
    _updateFilterCache();
  }

  void _syncLinesFromActiveBuffer() {
    final tab = activeTab;
    if (tab.paused && tab.pausedBufferSnapshot != null) {
      _lines
        ..clear()
        ..addAll(tab.pausedBufferSnapshot!);
      return;
    }
    final serial = activeTabSerial;
    if (serial != null) {
      final devBuf = _getOrCreateDeviceBuffer(serial);
      _lines
        ..clear()
        ..addAll(devBuf.lines);
    }
  }

  void _persistTabs() {
    unawaited(saveLogTabs(_tabs, _activeTabId));
  }

  /// Adds a new log tab (optionally targeting [deviceSerial], applying a
  /// [preset], or duplicating the active tab) and switches to it.
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

  /// Duplicates an existing tab and activates the copy.
  String duplicateTab(String tabId) {
    final idx = _tabs.indexWhere((t) => t.id == tabId);
    if (idx < 0) return addTab(duplicateCurrent: true);
    if (_activeTabId != tabId) {
      selectTab(tabId);
    }
    return addTab(duplicateCurrent: true);
  }

  /// Switches the active viewport to [tabId], saving the previous tab's filters
  /// and scroll state and recomputing against the target tab's device buffer.
  void selectTab(String tabId) {
    final targetIdx = _tabs.indexWhere((t) => t.id == tabId);
    if (targetIdx < 0) return;
    if (_activeTabId == tabId) return;

    _userModifiedTabs = true;
    _saveActiveTabFields();

    final prevSerial = activeTabSerial;
    _activeTabId = tabId;
    final target = _tabs[targetIdx];
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

    _syncLinesFromActiveBuffer();
    _recompute();

    if (_autoScroll) {
      scrollToBottom();
    } else {
      final offset = target.scrollOffset;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scrollController.hasClients) {
          final max = scrollController.position.maxScrollExtent;
          scrollController.jumpTo(offset.clamp(0.0, max));
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

  /// Changes the target device serial for the currently active tab without
  /// altering other tabs' target devices.
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

    _syncLinesFromActiveBuffer();
    _recompute();
    _persistTabs();
  }

  /// Switches to a tab showing [serial] (creating one if none exists yet),
  /// preserving backward compatibility with device-level navigation.
  void selectDeviceTab(String serial) {
    final currentEffective = activeTabSerial;
    if (currentEffective == serial && activeTab.deviceSerial == serial) return;

    // Pin the current tab to its active serial before switching away so its
    // filter state stays bound to that device.
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

    // If the sole tab has no device pinned and no logs/filters yet, reuse it;
    // otherwise open a dedicated tab for the target device.
    final isFreshSingleTab =
        _tabs.length == 1 &&
        activeTab.deviceSerial == null &&
        _lines.isEmpty &&
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

  void _trimVisibleToBufferStart() {
    if (_visible.isEmpty || _lines.isEmpty) return;
    final minSeq = _lines.first.seq;
    var trimCount = 0;
    while (trimCount < _visible.length && _visible[trimCount].seq < minSeq) {
      trimCount++;
    }
    if (trimCount > 0) {
      _visible.removeRange(0, trimCount);
    }
  }

  void _publishVisibleAndStats() {
    // UnmodifiableListView wraps _visible in O(1) without copying the list.
    visibleNotifier.value = UnmodifiableListView<LogEntry>(_visible);
    statsNotifier.value = (
      total: _lines.length,
      visible: _visible.length,
      hiddenNoise: _hiddenNoiseCount,
    );
  }

  bool _matchesEntry(
    LogEntry e, {
    required String currentPkg,
    required int? tabAppPid,
    required bool isNoise,
  }) {
    if (e.rank < _cachedMinRank) return false;

    if (currentPkg.isNotEmpty) {
      final lowerPkg = currentPkg.toLowerCase();
      final entryPkg = e.pkg?.toLowerCase();
      final matchesPkg = entryPkg != null && entryPkg.contains(lowerPkg);
      final matchesPid = tabAppPid != null && e.pid == tabAppPid;
      if (!matchesPkg && !matchesPid) return false;
    }

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
    _updateFilterCache();
    _visible.clear();
    int hidden = 0;
    final isReduced = _noiseMode == NoiseFilterMode.reduce;
    final needsNoiseCheck =
        isReduced ||
        _noiseMode == NoiseFilterMode.onlyNoise ||
        _cachedQuery.hasNoiseTerm;
    final currentPkg = pkgController.text.trim();
    final currentAppPid = appPid;
    final clearedAfter = activeTab.clearedAfterSeq;

    for (final e in _lines) {
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
        currentPkg: currentPkg,
        tabAppPid: currentAppPid,
        isNoise: isNoise,
      )) {
        _visible.add(e);
      } else if (isReduced && isNoise) {
        hidden++;
      }
    }
    _hiddenNoiseCount = hidden;
    _publishVisibleAndStats();
    notifyListeners();
  }

  // User Actions
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
    if (_paused) {
      activeTab.pausedBufferSnapshot = List<LogEntry>.of(_lines);
    } else {
      activeTab.pausedBufferSnapshot = null;
      _syncLinesFromActiveBuffer();
      _recompute();
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
    if (_lines.isNotEmpty) {
      activeTab.clearedAfterSeq = _lines.last.seq;
    }
    if (activeTab.paused) {
      activeTab.pausedBufferSnapshot = [];
      _lines.clear();
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

  String _formatEntry(LogEntry e, String currentPkg) {
    final parts = <String>[];
    final currentAppPid = appPid;
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

  Future<String> exportLogs() async {
    final buf = StringBuffer();
    final currentPkg = pkgController.text.trim();
    for (final e in _visible) {
      buf.writeln(_formatEntry(e, currentPkg));
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final filename = 'logcat_$stamp.log';

    return exportLog(buf.toString(), filename);
  }

  void copyLogEntry(LogEntry e) {
    Clipboard.setData(
      ClipboardData(text: _formatEntry(e, pkgController.text.trim())),
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
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
    searchController.dispose();
    pkgController.dispose();
    visibleNotifier.dispose();
    statsNotifier.dispose();
    stopBridge();
    super.dispose();
  }
}
