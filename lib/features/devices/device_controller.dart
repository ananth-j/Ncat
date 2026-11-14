import 'package:flutter/foundation.dart';

import '../logcat/models/log_entry.dart';
import 'models/device_info.dart';

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

/// Manages device discovery, active serial selection, tab states, and matrix/grid view modes.
class DeviceController extends ChangeNotifier {
  DeviceController({
    List<DeviceInfo> initialDevices = const [],
    String? initialActiveDevice,
  })  : _devices = initialDevices,
        _activeDevice = initialActiveDevice,
        _pickedDevice = initialActiveDevice;

  List<DeviceInfo> _devices = const [];
  String? _activeDevice;
  String? _pickedDevice;
  DeviceViewMode _viewMode = DeviceViewMode.singleOrTabs;

  final Map<String, DeviceTabState> _tabStates = {};

  // Getters
  List<DeviceInfo> get devices => _devices;
  String? get activeDevice => _activeDevice;
  String? get pickedDevice => _pickedDevice;
  DeviceViewMode get viewMode => _viewMode;
  Map<String, DeviceTabState> get tabStates => Map.unmodifiable(_tabStates);

  /// Retrieves or creates an isolated session state for a given device serial.
  DeviceTabState getOrCreateTab(String serial) {
    return _tabStates.putIfAbsent(serial, () => DeviceTabState(serial: serial));
  }

  /// Updates the connected devices list from server status messages.
  void updateDevices(List<DeviceInfo> devices, {String? serverActiveDevice}) {
    _devices = devices;
    if (_activeDevice == null || !_devices.any((d) => d.serial == _activeDevice)) {
      _activeDevice = serverActiveDevice ?? (_devices.isNotEmpty ? _devices.first.serial : null);
      _pickedDevice = _activeDevice;
    }
    final activeSerials = _devices.map((d) => d.serial).toSet();
    _tabStates.removeWhere((k, _) => !activeSerials.contains(k));
    notifyListeners();
  }

  /// Changes the currently active device tab.
  void setActiveDevice(String? serial) {
    if (_activeDevice == serial) return;
    _activeDevice = serial;
    _pickedDevice = serial;
    notifyListeners();
  }

  /// Changes the display view mode (Tabs vs MultiScreenGrid).
  void setViewMode(DeviceViewMode mode) {
    if (_viewMode == mode) return;
    _viewMode = mode;
    notifyListeners();
  }

  /// Toggles between single/tabs view and matrix grid view.
  void toggleViewMode() {
    _viewMode = _viewMode == DeviceViewMode.singleOrTabs
        ? DeviceViewMode.grid
        : DeviceViewMode.singleOrTabs;
    notifyListeners();
  }

  /// Applies device selection from dropdown or UI picker.
  void applyDevice(String? serial) {
    _pickedDevice = serial;
    if (serial != null && serial.isNotEmpty) {
      setActiveDevice(serial);
    }
    notifyListeners();
  }
}
