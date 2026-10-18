import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/features/mirroring/mirror_controller.dart';
import 'package:wcat/features/mirroring/services/capture_client.dart';
import 'package:wcat/features/mirroring/widgets/scrcpy_install_dialog.dart';

class _FakeClient implements CaptureClient {
  Map<String, dynamic>? mockPostJsonResult;
  bool installCalled = false;

  @override
  Future<Map<String, dynamic>?> postJson(
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
    if (uri.path == '/api/scrcpy/install') {
      installCalled = true;
    }
    return mockPostJsonResult ?? {'status': 'ok'};
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
  group('ScrcpyInstallDialog Widget Tests', () {
    late _FakeClient client;
    late MirrorController controller;

    setUp(() {
      client = _FakeClient();
      controller = MirrorController(client: client);
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('Renders dialog content and installs scrcpy on button tap', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScrcpyInstallDialog(
              controller: controller,
              serial: 'device-test-1',
            ),
          ),
        ),
      );

      expect(find.text('Hardware-Accelerated Mirroring'), findsOneWidget);
      expect(find.text('60 FPS Ultra-Smooth Mirroring'), findsOneWidget);
      expect(find.text('0% Host CPU Overhead'), findsOneWidget);
      expect(find.text('Install scrcpy'), findsOneWidget);

      await tester.tap(find.text('Install scrcpy'));
      await tester.pump();

      expect(client.installCalled, isTrue);
    });
  });
}
