import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/features/mirroring/mirror_controller.dart';
import 'package:wcat/features/mirroring/services/capture_client.dart';
import 'package:wcat/features/mirroring/services/scrcpy_dock_stub.dart';
import 'package:wcat/features/mirroring/widgets/embedded_mirror_panel.dart';

class _FakeClient implements CaptureClient {
  Map<String, dynamic>? mockLaunchResult;
  List<Map<String, dynamic>> postedInputs = [];
  bool stopScrcpyCalled = false;

  @override
  Future<Map<String, dynamic>?> postJson(
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
    if (uri.path == '/api/scrcpy/launch') {
      return mockLaunchResult ?? {'status': 'launched', 'pid': 12345};
    }
    if (uri.path == '/api/scrcpy/stop') {
      stopScrcpyCalled = true;
      return {'status': 'stopped'};
    }
    if (uri.path == '/api/input' && body != null) {
      postedInputs.add(body);
      return {'status': 'ok'};
    }
    return {'status': 'ok'};
  }

  @override
  Future<Map<String, dynamic>?> getJson(Uri uri) async => null;

  @override
  Future<Uint8List?> getScreenshot(Uri uri) async => null;

  @override
  Future<bool> startRecord(Uri uri) async => true;

  @override
  Future<Uint8List?> stopRecord(Uri uri) async => null;
}

void main() {
  group('EmbeddedMirrorPanel Widget Tests', () {
    late _FakeClient client;
    late MirrorController controller;

    setUp(() {
      client = _FakeClient();
      controller = MirrorController(client: client);
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('Renders header bar with device serial and action buttons', (
      tester,
    ) async {
      bool closed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmbeddedMirrorPanel(
              controller: controller,
              serial: 'emulator-5554',
              onClose: () => closed = true,
              dockService: ScrcpyDockStub(),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('Mirror • emulator-5554'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
      expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
      expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
      expect(find.byIcon(Icons.power_settings_new_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      // Tap Back button
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pump();
      expect(client.postedInputs, isNotEmpty);
      expect(client.postedInputs.last['action'], equals('key'));
      expect(client.postedInputs.last['keyCode'], equals(4));

      // Tap Close button
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(closed, isTrue);
    });

    testWidgets('Shows not installed state when scrcpy is missing', (
      tester,
    ) async {
      client.mockLaunchResult = {
        'status': 'not_installed',
        'message': 'scrcpy not found',
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmbeddedMirrorPanel(
              controller: controller,
              serial: 'emulator-5554',
              onClose: () {},
              dockService: ScrcpyDockStub(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('scrcpy Not Installed'), findsOneWidget);
      expect(find.text('Install scrcpy'), findsOneWidget);
    });
  });
}
