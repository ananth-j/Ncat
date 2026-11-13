import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'services/capture_client.dart';

/// Starts and manages the native scrcpy client used for live screen mirroring.
class MirrorController {
  MirrorController({
    CaptureClient? client,
    String? bridgeHost,
    int bridgePort = 8080,
  }) : _client = client ?? CaptureClient(),
       _bridgeHost =
           bridgeHost ?? (Uri.base.host.isEmpty ? '127.0.0.1' : Uri.base.host),
       _bridgePort = bridgePort;

  static const _embedChannel = MethodChannel('ThruWire/scrcpy_embed');

  final CaptureClient _client;
  final String _bridgeHost;
  final int _bridgePort;

  final ValueNotifier<bool> isOpen = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isPaused = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isScrcpyRunning = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isScrcpyEmbedded = ValueNotifier<bool>(false);
  final ValueNotifier<String?> errorMessage = ValueNotifier<String?>(null);
  final ValueNotifier<String?> lastScrcpyStatus = ValueNotifier<String?>(null);

  String? activeSerial;
  bool _isDisposed = false;
  int _openCycle = 0;

  void toggleOpen({String? serial}) => setOpen(!isOpen.value, serial: serial);

  void setOpen(bool open, {String? serial}) {
    if (_isDisposed) return;
    _openCycle++;
    isOpen.value = open;
    if (serial != null) activeSerial = serial;

    if (open) {
      if (!isPaused.value && !isScrcpyRunning.value) {
        unawaited(launchScrcpyWithStatus(serial: activeSerial));
      }
      return;
    }

    unawaited(_stopScrcpySession());
    isScrcpyEmbedded.value = false;
    isScrcpyRunning.value = false;
  }

  /// Stops mirroring while the host app is backgrounded. The scrcpy window is
  /// owned by the host window, so minimizing the app hides it with the app.
  void onPause() => isPaused.value = true;

  void onResume() {
    isPaused.value = false;
    if (isOpen.value && !isScrcpyRunning.value) {
      unawaited(launchScrcpyWithStatus(serial: activeSerial));
    }
  }

  Future<String> launchScrcpyWithStatus({String? serial}) async {
    final targetSerial = serial ?? activeSerial;
    if (targetSerial == null || targetSerial.isEmpty) {
      lastScrcpyStatus.value = 'error';
      errorMessage.value = 'No active device selected';
      return 'error';
    }

    activeSerial = targetSerial;
    final launchCycle = _openCycle;
    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/scrcpy/launch',
      queryParameters: {'serial': targetSerial},
    );

    final res = await _client.postJson(uri);
    final status = res?['status']?.toString() ?? 'error';
    if (_isDisposed || launchCycle != _openCycle) {
      if (status == 'launched') await _requestStopScrcpy(targetSerial);
      return status;
    }
    lastScrcpyStatus.value = status;

    if (status == 'launched') {
      errorMessage.value = null;
      isScrcpyRunning.value = true;
      isScrcpyEmbedded.value =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    } else {
      isScrcpyRunning.value = false;
      isScrcpyEmbedded.value = false;
      errorMessage.value =
          res?['message']?.toString() ?? 'Unable to launch scrcpy';
    }
    return status;
  }

  Future<bool> launchScrcpy({String? serial}) async =>
      await launchScrcpyWithStatus(serial: serial) == 'launched';

  Future<void> _detachEmbeddedWindow() async {
    try {
      await _embedChannel.invokeMethod<void>('detach', {
        'title': 'ThruWire mirror - $activeSerial',
      });
    } on MissingPluginException {
      // Only the Windows desktop runner embeds the native scrcpy window.
    } on PlatformException {
      // The scrcpy process may already have closed its window.
    }
  }

  Future<void> _stopScrcpySession() async {
    if (isScrcpyEmbedded.value) await _detachEmbeddedWindow();
    final serial = activeSerial;
    if (serial == null) return;
    await _requestStopScrcpy(serial);
  }

  Future<void> _requestStopScrcpy(String serial) async {
    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/scrcpy/stop',
      queryParameters: {'serial': serial},
    );
    await _client.postJson(uri);
  }

  Future<Map<String, dynamic>?> checkScrcpyStatus() async {
    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/scrcpy/status',
    );
    return _client.getJson(uri);
  }

  Future<Map<String, dynamic>?> installScrcpy() async {
    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/scrcpy/install',
    );
    return _client.postJson(uri);
  }

  void dispose() {
    _isDisposed = true;
    if (isScrcpyRunning.value) unawaited(_stopScrcpySession());
    isOpen.dispose();
    isPaused.dispose();
    isScrcpyRunning.dispose();
    isScrcpyEmbedded.dispose();
    errorMessage.dispose();
    lastScrcpyStatus.dispose();
  }
}
