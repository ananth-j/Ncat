import 'dart:typed_data';
import 'dart:ui' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/features/mirroring/mirror_controller.dart';
import 'package:wcat/features/mirroring/services/capture_client.dart';

class MockMirrorCaptureClient implements CaptureClient {
  Uri? lastPostJsonUri;
  Map<String, dynamic>? lastPostJsonBody;
  Map<String, dynamic>? mockPostJsonResult;

  @override
  Future<Map<String, dynamic>?> postJson(
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
    lastPostJsonUri = uri;
    lastPostJsonBody = body;
    return mockPostJsonResult ?? {'status': 'ok'};
  }

  Uri? lastGetJsonUri;
  Map<String, dynamic>? mockGetJsonResult;

  @override
  Future<Map<String, dynamic>?> getJson(Uri uri) async {
    lastGetJsonUri = uri;
    return mockGetJsonResult;
  }

  @override
  Future<Uint8List?> getScreenshot(Uri uri) async => null;

  @override
  Future<bool> startRecord(Uri uri) async => true;

  @override
  Future<Uint8List?> stopRecord(Uri uri) async => null;
}

void main() {
  group('MirrorController Unit Tests (Phase 4)', () {
    late MockMirrorCaptureClient mockClient;
    late MirrorController controller;

    setUp(() {
      mockClient = MockMirrorCaptureClient();
      controller = MirrorController(
        client: mockClient,
        bridgeHost: '127.0.0.1',
        bridgePort: 8080,
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('toggleOpen and setOpen controls pane state and stream lifecycle', () {
      expect(controller.isOpen.value, isFalse);
      expect(controller.isStreaming.value, isFalse);

      controller.toggleOpen(serial: 'test-device-1');
      expect(controller.isOpen.value, isTrue);
      expect(controller.activeSerial, 'test-device-1');

      controller.setOpen(false);
      expect(controller.isOpen.value, isFalse);
      expect(controller.isStreaming.value, isFalse);
    });

    test('setFps clamps framerate between 1 and 30', () {
      controller.setFps(60);
      expect(controller.fps.value, 30);

      controller.setFps(0);
      expect(controller.fps.value, 1);

      controller.setFps(15);
      expect(controller.fps.value, 15);
    });

    test(
      'sendTap converts widget coordinates to physical device coordinates',
      () async {
        controller.activeSerial = 'device-tap-1';
        controller.deviceDimensions = const Size(1080, 2400);

        // Tap at center of 300x600 widget
        await controller.sendTap(const Offset(150, 300), const Size(300, 600));

        expect(mockClient.lastPostJsonUri?.path, '/api/input');
        expect(mockClient.lastPostJsonBody?['action'], 'tap');
        expect(mockClient.lastPostJsonBody?['serial'], 'device-tap-1');
        expect(mockClient.lastPostJsonBody?['x'], 540); // 150/300 * 1080
        expect(mockClient.lastPostJsonBody?['y'], 1200); // 300/600 * 2400
      },
    );

    test(
      'sendSwipe converts drag gestures to physical device coordinates',
      () async {
        controller.activeSerial = 'device-swipe-1';
        controller.deviceDimensions = const Size(1080, 2400);

        // Swipe from top to bottom
        await controller.sendSwipe(
          const Offset(150, 100),
          const Offset(150, 500),
          const Size(300, 600),
          durationMs: 250,
        );

        expect(mockClient.lastPostJsonUri?.path, '/api/input');
        expect(mockClient.lastPostJsonBody?['action'], 'swipe');
        expect(mockClient.lastPostJsonBody?['serial'], 'device-swipe-1');
        expect(mockClient.lastPostJsonBody?['x1'], 540);
        expect(mockClient.lastPostJsonBody?['y1'], 400);
        expect(mockClient.lastPostJsonBody?['x2'], 540);
        expect(mockClient.lastPostJsonBody?['y2'], 2000);
        expect(mockClient.lastPostJsonBody?['durationMs'], 250);
      },
    );

    test('sendKey forwards Android keyevent', () async {
      controller.activeSerial = 'device-key-1';

      await controller.sendKey(4); // Back

      expect(mockClient.lastPostJsonUri?.path, '/api/input');
      expect(mockClient.lastPostJsonBody?['action'], 'key');
      expect(mockClient.lastPostJsonBody?['keyCode'], 4);
      expect(mockClient.lastPostJsonBody?['serial'], 'device-key-1');
    });

    test('sendText forwards text input', () async {
      controller.activeSerial = 'device-text-1';

      await controller.sendText('hello world');

      expect(mockClient.lastPostJsonUri?.path, '/api/input');
      expect(mockClient.lastPostJsonBody?['action'], 'text');
      expect(mockClient.lastPostJsonBody?['text'], 'hello world');
    });

    test('launchScrcpy invokes bridge endpoint and handles response', () async {
      controller.activeSerial = 'device-scrcpy-1';
      mockClient.mockPostJsonResult = {
        'status': 'launched',
        'serial': 'device-scrcpy-1',
      };

      final ok = await controller.launchScrcpy();
      expect(ok, isTrue);
      expect(controller.lastScrcpyStatus.value, 'launched');
      expect(mockClient.lastPostJsonUri?.path, '/api/scrcpy/launch');
      expect(
        mockClient.lastPostJsonUri?.queryParameters['serial'],
        'device-scrcpy-1',
      );
    });

    test(
      'launchScrcpyWithStatus returns not_installed when binary missing',
      () async {
        controller.activeSerial = 'device-scrcpy-1';
        mockClient.mockPostJsonResult = {
          'status': 'not_installed',
          'message': 'scrcpy not installed',
        };

        final status = await controller.launchScrcpyWithStatus();
        expect(status, 'not_installed');
        expect(controller.lastScrcpyStatus.value, 'not_installed');
        expect(controller.errorMessage.value, 'scrcpy not installed');
      },
    );

    test('checkScrcpyStatus queries /api/scrcpy/status', () async {
      mockClient.mockGetJsonResult = {
        'installed': true,
        'path': '/usr/bin/scrcpy',
        'version': 'v5.0.1',
      };

      final res = await controller.checkScrcpyStatus();
      expect(res?['installed'], isTrue);
      expect(res?['path'], '/usr/bin/scrcpy');
      expect(mockClient.lastGetJsonUri?.path, '/api/scrcpy/status');
    });

    test('installScrcpy posts to /api/scrcpy/install', () async {
      mockClient.mockPostJsonResult = {'status': 'ok', 'version': 'v5.0.1'};

      final res = await controller.installScrcpy();
      expect(res?['status'], 'ok');
      expect(mockClient.lastPostJsonUri?.path, '/api/scrcpy/install');
    });

    test('onPause and onResume handles window lifecycle', () {
      controller.setOpen(true, serial: 'device-lifecycle-1');

      controller.onPause();
      expect(controller.isPaused.value, isTrue);
      expect(controller.isStreaming.value, isFalse);

      controller.onResume();
      expect(controller.isPaused.value, isFalse);
    });
  });
}
