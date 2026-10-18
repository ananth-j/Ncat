import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'process_runner.dart';

class AdbDeviceEntry {
  final String serial;
  final String state;
  final String? model;

  const AdbDeviceEntry({required this.serial, required this.state, this.model});

  bool get isAuthorized => state == 'device';

  Map<String, dynamic> toJson() => {
    'serial': serial,
    'model':
        model ??
        (state == 'unauthorized'
            ? 'Unauthorized (Accept USB debugging)'
            : state),
    'authorized': isAuthorized,
  };
}

/// Tracks connected Android devices via push-based `adb track-devices` stream.
///
/// Avoids CPU-intensive polling and zero CPU footprint while idle.
class AdbTracker {
  AdbTracker({
    required this.adbPath,
    this.processRunner = const RealProcessRunner(),
    this.onDevicesChanged,
    this.onError,
  });

  final String adbPath;
  final ProcessRunner processRunner;
  final void Function(List<AdbDeviceEntry> devices)? onDevicesChanged;
  final void Function(String error)? onError;

  Process? _process;
  Timer? _reconnectTimer;
  bool _isDisposed = false;
  List<AdbDeviceEntry> _currentDevices = const [];

  List<AdbDeviceEntry> get devices => _currentDevices;

  /// Starts the push-based device listener.
  Future<void> start() async {
    _isDisposed = false;
    _reconnectTimer?.cancel();
    await _startTracking();
  }

  Future<void> _startTracking() async {
    if (_isDisposed) return;

    // Refresh model metadata initially
    await _refreshFullDeviceList();

    try {
      final p = await processRunner.start(adbPath, ['track-devices']);
      _process = p;

      p.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            _onTrackLine,
            onError: (Object e) {
              onError?.call('track-devices stdout error: $e');
              _scheduleReconnect();
            },
          );

      p.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((l) => onError?.call('track-devices: $l'));

      unawaited(
        p.exitCode.then((code) {
          if (_process == p) {
            _process = null;
          }
          if (!_isDisposed) {
            _scheduleReconnect();
          }
        }),
      );
    } catch (e) {
      onError?.call('Could not start adb track-devices: $e');
      _scheduleReconnect();
    }
  }

  void _onTrackLine(String line) async {
    // On any change event from track-devices (including empty line on disconnect),
    // refresh device list to accurately capture current devices and authorizations.
    await _refreshFullDeviceList();
  }

  Future<void> _refreshFullDeviceList() async {
    if (_isDisposed) return;
    try {
      final r = await processRunner.run(adbPath, ['devices', '-l']);
      final output = r.stdout as String;
      final parsed = parseAdbDevicesOutput(output);

      _currentDevices = parsed;
      onDevicesChanged?.call(_currentDevices);
    } catch (e) {
      onError?.call('Failed to refresh devices: $e');
    }
  }

  static List<AdbDeviceEntry> parseAdbDevicesOutput(String stdout) {
    final devices = <AdbDeviceEntry>[];
    for (final line in stdout.split('\n').skip(1)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;

      final serial = parts[0];
      final state = parts[1];

      if (state == 'unauthorized') {
        devices.add(
          AdbDeviceEntry(
            serial: serial,
            state: state,
            model: 'Unauthorized (Accept USB debugging)',
          ),
        );
        continue;
      }
      if (state == 'offline') {
        devices.add(
          AdbDeviceEntry(serial: serial, state: state, model: 'Offline'),
        );
        continue;
      }
      if (state != 'device') continue;

      String? model;
      for (final p in parts.skip(2)) {
        if (p.startsWith('model:')) model = p.substring(6);
      }
      devices.add(AdbDeviceEntry(serial: serial, state: state, model: model));
    }
    return devices;
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!_isDisposed) {
        _startTracking();
      }
    });
  }

  Future<void> stop() async {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final p = _process;
    _process = null;
    if (p != null) {
      try {
        p.kill();
      } catch (_) {}
    }
  }
}
