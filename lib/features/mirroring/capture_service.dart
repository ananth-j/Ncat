import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../src/export.dart';
import 'services/capture_client.dart';

/// Service managing device screenshot capture, screen recording lifecycle,
/// and file export.
class CaptureService {
  CaptureService({
    CaptureClient? client,
    String? bridgeHost,
    int bridgePort = 8080,
  }) : _client = client ?? CaptureClient(),
       _bridgeHost =
           bridgeHost ?? (Uri.base.host.isEmpty ? '127.0.0.1' : Uri.base.host),
       _bridgePort = bridgePort;

  final CaptureClient _client;
  final String _bridgeHost;
  final int _bridgePort;

  final ValueNotifier<bool> isTakingScreenshot = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isRecording = ValueNotifier<bool>(false);
  final ValueNotifier<Duration> recordingDuration = ValueNotifier<Duration>(
    Duration.zero,
  );
  final ValueNotifier<String?> activeRecordingSerial = ValueNotifier<String?>(
    null,
  );

  Timer? _recordTimer;
  DateTime? _recordingStartTime;

  Uri _screenshotUri(String? serial) {
    return Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/screenshot',
      queryParameters: serial != null ? {'serial': serial} : null,
    );
  }

  Uri _recordStartUri(String? serial, int bitRate) {
    return Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/record/start',
      queryParameters: {
        if (serial != null) 'serial': serial,
        'bitRate': bitRate.toString(),
      },
    );
  }

  Uri _recordStopUri(String? serial) {
    return Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/record/stop',
      queryParameters: serial != null ? {'serial': serial} : null,
    );
  }

  int _activeScreenshotCount = 0;

  /// Takes an instant screenshot from the active device and returns the raw PNG bytes.
  Future<Uint8List?> takeScreenshot({String? serial}) async {
    _activeScreenshotCount++;
    isTakingScreenshot.value = true;
    try {
      final bytes = await _client.getScreenshot(_screenshotUri(serial));
      return bytes;
    } finally {
      _activeScreenshotCount--;
      if (_activeScreenshotCount <= 0) {
        _activeScreenshotCount = 0;
        isTakingScreenshot.value = false;
      }
    }
  }

  /// Starts native hardware-encoded screen recording on the target device.
  Future<bool> startRecording({String? serial, int bitRate = 6000000}) async {
    if (isRecording.value) return false;

    final success = await _client.startRecord(_recordStartUri(serial, bitRate));
    if (success) {
      isRecording.value = true;
      activeRecordingSerial.value = serial;
      _recordingStartTime = DateTime.now();
      recordingDuration.value = Duration.zero;

      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_recordingStartTime != null) {
          recordingDuration.value = DateTime.now().difference(
            _recordingStartTime!,
          );
        }
      });
      return true;
    }
    return false;
  }

  /// Gracefully stops recording, finalizes the MP4 on device, pulls, and returns the MP4 bytes.
  Future<Uint8List?> stopRecording({String? serial}) async {
    if (!isRecording.value) return null;

    final targetSerial = serial ?? activeRecordingSerial.value;
    try {
      final bytes = await _client.stopRecord(_recordStopUri(targetSerial));
      return bytes;
    } finally {
      _recordTimer?.cancel();
      _recordTimer = null;
      _recordingStartTime = null;
      isRecording.value = false;
      activeRecordingSerial.value = null;
      recordingDuration.value = Duration.zero;
    }
  }

  /// Exports screenshot bytes to user's Downloads directory.
  Future<String> saveScreenshot(List<int> bytes, {String? serial}) async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final filename = 'screenshot_${serial ?? 'device'}_$timestamp.png';
    return exportBinary(bytes, filename);
  }

  /// Exports MP4 recording bytes to user's Downloads directory.
  Future<String> saveRecording(List<int> bytes, {String? serial}) async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final filename = 'screenrecord_${serial ?? 'device'}_$timestamp.mp4';
    return exportBinary(bytes, filename);
  }

  void dispose() {
    _recordTimer?.cancel();
    isTakingScreenshot.dispose();
    isRecording.dispose();
    recordingDuration.dispose();
    activeRecordingSerial.dispose();
  }
}
