import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'services/capture_client.dart';

/// Manages real-time screen mirroring stream, quality controls, touch/key input forwarding,
/// and hardware-accelerated scrcpy fallback.
class MirrorController {
  MirrorController({
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

  final ValueNotifier<bool> isOpen = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isStreaming = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isPaused = ValueNotifier<bool>(false);
  final ValueNotifier<int> fps = ValueNotifier<int>(15);
  final ValueNotifier<double> aspectRatio = ValueNotifier<double>(9 / 19.5);
  final ValueNotifier<ui.Image?> currentFrame = ValueNotifier<ui.Image?>(null);
  final ValueNotifier<String?> errorMessage = ValueNotifier<String?>(null);

  Size? deviceDimensions;
  String? activeSerial;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool _isDisposed = false;

  void toggleOpen({String? serial}) {
    setOpen(!isOpen.value, serial: serial);
  }

  void setOpen(bool open, {String? serial}) {
    if (_isDisposed) return;
    isOpen.value = open;
    if (serial != null) activeSerial = serial;

    if (open) {
      if (!isPaused.value) {
        startStream(serial: activeSerial);
      }
    } else {
      stopStream();
    }
  }

  void setFps(int newFps) {
    if (fps.value == newFps) return;
    fps.value = newFps.clamp(1, 30);
    if (isStreaming.value) {
      // Restart stream with new fps parameter
      startStream(serial: activeSerial);
    }
  }

  /// Connects to the dedicated screen streaming endpoint on the bridge.
  void startStream({String? serial}) {
    if (_isDisposed) return;
    stopStream();

    activeSerial = serial ?? activeSerial;
    final targetSerial = activeSerial;
    if (targetSerial == null || targetSerial.isEmpty) {
      errorMessage.value = 'No active device selected';
      return;
    }

    errorMessage.value = null;
    isStreaming.value = true;

    final uri = Uri(
      scheme: 'ws',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/stream',
      queryParameters: {'serial': targetSerial, 'fps': fps.value.toString()},
    );

    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;

      _sub = channel.stream.listen(
        (dynamic message) {
          if (message is Uint8List) {
            _handleIncomingBytes(message);
          } else if (message is List<int>) {
            _handleIncomingBytes(Uint8List.fromList(message));
          }
        },
        onError: (err) {
          if (_channel == channel) {
            errorMessage.value = 'Stream connection error: $err';
            isStreaming.value = false;
          }
        },
        onDone: () {
          if (_channel == channel) {
            isStreaming.value = false;
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      errorMessage.value = 'Failed to connect stream: $e';
      isStreaming.value = false;
    }
  }

  /// Stops the active mirroring stream and cancels the socket connection.
  void stopStream() {
    _sub?.cancel();
    _sub = null;

    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    isStreaming.value = false;
  }

  /// Called when the application window minimizes or moves to background.
  void onPause() {
    isPaused.value = true;
    stopStream();
  }

  /// Called when the application returns to foreground.
  void onResume() {
    isPaused.value = false;
    if (isOpen.value && activeSerial != null) {
      startStream(serial: activeSerial);
    }
  }

  Future<void> _handleIncomingBytes(Uint8List bytes) async {
    if (_isDisposed || isPaused.value || !isOpen.value) return;

    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      final newImage = frameInfo.image;

      if (_isDisposed || !isOpen.value) {
        newImage.dispose();
        return;
      }

      deviceDimensions = Size(
        newImage.width.toDouble(),
        newImage.height.toDouble(),
      );
      aspectRatio.value = newImage.width / newImage.height;

      // Swap frame and dispose previous image to maintain strict single-frame memory ceiling
      final oldImage = currentFrame.value;
      currentFrame.value = newImage;
      oldImage?.dispose();
    } catch (_) {}
  }

  /// Status of the last scrcpy launch attempt ('launched', 'not_installed', 'error').
  final ValueNotifier<String?> lastScrcpyStatus = ValueNotifier<String?>(null);

  /// Launches external scrcpy window with detailed status return.
  Future<String> launchScrcpyWithStatus({String? serial}) async {
    final targetSerial = serial ?? activeSerial;
    if (targetSerial == null) {
      lastScrcpyStatus.value = 'error';
      return 'error';
    }

    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/scrcpy/launch',
      queryParameters: {'serial': targetSerial},
    );

    final res = await _client.postJson(uri);
    final status = res?['status']?.toString() ?? 'error';
    lastScrcpyStatus.value = status;

    if (status == 'launched') {
      errorMessage.value = null;
    } else {
      errorMessage.value =
          res?['message']?.toString() ?? 'scrcpy not found in system PATH';
    }
    return status;
  }

  /// Launches external scrcpy window (Phase 4.1 quick win, 0% host CPU overhead).
  Future<bool> launchScrcpy({String? serial}) async {
    final status = await launchScrcpyWithStatus(serial: serial);
    return status == 'launched';
  }

  /// Checks whether scrcpy binary is installed on the host system.
  Future<Map<String, dynamic>?> checkScrcpyStatus() async {
    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/scrcpy/status',
    );
    return await _client.getJson(uri);
  }

  /// Requests the bridge to download and install the official standalone scrcpy binary.
  Future<Map<String, dynamic>?> installScrcpy() async {
    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/scrcpy/install',
    );
    return await _client.postJson(uri);
  }

  /// Sends a touch tap mapped from local widget coordinates to physical device coordinates.
  Future<void> sendTap(
    Offset localPos,
    Size widgetSize, {
    String? serial,
  }) async {
    final targetSerial = serial ?? activeSerial;
    if (targetSerial == null ||
        widgetSize.width <= 0 ||
        widgetSize.height <= 0) {
      return;
    }

    final devW = deviceDimensions?.width ?? 1080;
    final devH = deviceDimensions?.height ?? 2400;

    final normX = (localPos.dx / widgetSize.width).clamp(0.0, 1.0);
    final normY = (localPos.dy / widgetSize.height).clamp(0.0, 1.0);
    final x = (normX * devW).round();
    final y = (normY * devH).round();

    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/input',
    );

    await _client.postJson(uri, {
      'action': 'tap',
      'serial': targetSerial,
      'x': x,
      'y': y,
    });
  }

  /// Sends a drag/swipe gesture mapped from local widget coordinates to physical device coordinates.
  Future<void> sendSwipe(
    Offset start,
    Offset end,
    Size widgetSize, {
    int durationMs = 300,
    String? serial,
  }) async {
    final targetSerial = serial ?? activeSerial;
    if (targetSerial == null ||
        widgetSize.width <= 0 ||
        widgetSize.height <= 0) {
      return;
    }

    final devW = deviceDimensions?.width ?? 1080;
    final devH = deviceDimensions?.height ?? 2400;

    final x1 = ((start.dx / widgetSize.width).clamp(0.0, 1.0) * devW).round();
    final y1 = ((start.dy / widgetSize.height).clamp(0.0, 1.0) * devH).round();
    final x2 = ((end.dx / widgetSize.width).clamp(0.0, 1.0) * devW).round();
    final y2 = ((end.dy / widgetSize.height).clamp(0.0, 1.0) * devH).round();

    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/input',
    );

    await _client.postJson(uri, {
      'action': 'swipe',
      'serial': targetSerial,
      'x1': x1,
      'y1': y1,
      'x2': x2,
      'y2': y2,
      'durationMs': durationMs,
    });
  }

  /// Sends an Android keycode (Back: 4, Home: 3, Recents: 187, Power: 26, VolUp: 24, VolDown: 25).
  Future<void> sendKey(int keyCode, {String? serial}) async {
    final targetSerial = serial ?? activeSerial;
    if (targetSerial == null) return;

    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/input',
    );

    await _client.postJson(uri, {
      'action': 'key',
      'serial': targetSerial,
      'keyCode': keyCode,
    });
  }

  /// Sends text to active focused field.
  Future<void> sendText(String text, {String? serial}) async {
    final targetSerial = serial ?? activeSerial;
    if (targetSerial == null || text.isEmpty) return;

    final uri = Uri(
      scheme: 'http',
      host: _bridgeHost,
      port: _bridgePort,
      path: '/api/input',
    );

    await _client.postJson(uri, {
      'action': 'text',
      'serial': targetSerial,
      'text': text,
    });
  }

  void dispose() {
    _isDisposed = true;
    stopStream();

    final oldImage = currentFrame.value;
    currentFrame.value = null;
    oldImage?.dispose();

    isOpen.dispose();
    isStreaming.dispose();
    isPaused.dispose();
    fps.dispose();
    aspectRatio.dispose();
    currentFrame.dispose();
    errorMessage.dispose();
    lastScrcpyStatus.dispose();
  }
}
