import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/features/devices/models/device_info.dart';
import 'package:wcat/features/devices/widgets/device_tab_bar.dart';
import 'package:wcat/features/logcat/logcat_controller.dart';
import 'package:wcat/features/logcat/models/log_entry.dart';
import 'package:wcat/features/mirroring/capture_service.dart';
import 'package:wcat/features/mirroring/services/capture_client.dart';
import 'package:wcat/features/mirroring/widgets/multi_screen_grid.dart';
import 'package:wcat/protocol/messages.dart';
import 'package:wcat/src/palette.dart';

class MockMatrixCaptureClient implements CaptureClient {
  final List<String> capturedSerials = [];

  @override
  Future<Uint8List?> getScreenshot(Uri uri) async {
    final serial = uri.queryParameters['serial'] ?? 'default';
    capturedSerials.add(serial);
    return Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
  }

  @override
  Future<bool> startRecord(Uri uri) async => true;

  @override
  Future<Uint8List?> stopRecord(Uri uri) async => null;

  @override
  Future<Map<String, dynamic>?> postJson(
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
    return {'status': 'ok'};
  }
}

void main() {
  group('Phase 5: Multi-Device Matrix & Tabs Tests', () {
    late LogcatController controller;

    setUp(() {
      controller = LogcatController();
    });

    tearDown(() {
      controller.dispose();
    });

    test(
      '5.1 Tabs Mode: Incoming batches route to isolated device buffers',
      () {
        // Simulate connected devices status message
        controller.handleMessage(
          const StatusMessage(
            status: 'connected',
            devices: [
              DeviceInfo(serial: 'dev-1', model: 'Pixel 7', authorized: true),
              DeviceInfo(
                serial: 'dev-2',
                model: 'Galaxy S23',
                authorized: true,
              ),
            ],
            activeDevice: 'dev-1',
          ),
        );

        expect(controller.activeDevice, 'dev-1');

        // Send logs specifically for dev-1
        controller.handleMessage(
          const LogBatchMessage([
            LogEntry(
              time: '12:00:00',
              pid: 1,
              tid: 1,
              level: 'I',
              tag: 'Dev1',
              msg: 'Hello from dev 1',
              seq: 1,
            ),
          ], serial: 'dev-1'),
        );

        // Send logs specifically for dev-2 (background tab)
        controller.handleMessage(
          const LogBatchMessage([
            LogEntry(
              time: '12:00:01',
              pid: 2,
              tid: 2,
              level: 'E',
              tag: 'Dev2',
              msg: 'Crash on dev 2',
              seq: 2,
            ),
            LogEntry(
              time: '12:00:02',
              pid: 2,
              tid: 2,
              level: 'E',
              tag: 'Dev2',
              msg: 'Crash log 2',
              seq: 3,
            ),
          ], serial: 'dev-2'),
        );

        // Verify active view contains only dev-1 logs
        expect(controller.lines.length, 1);
        expect(controller.lines.first.tag, 'Dev1');

        // Verify dev-2 logs were buffered in isolated tab state
        final dev2Tab = controller.tabStates['dev-2'];
        expect(dev2Tab, isNotNull);
        expect(dev2Tab!.lines.length, 2);
        expect(dev2Tab.lines.first.tag, 'Dev2');

        // Switch to dev-2 tab
        controller.selectDeviceTab('dev-2');
        expect(controller.activeDevice, 'dev-2');
        expect(controller.lines.length, 2);
        expect(controller.lines.first.msg, 'Crash on dev 2');
      },
    );

    test('5.1 Tabs Mode: Tab filter queries are preserved per-device', () {
      controller.handleMessage(
        const StatusMessage(
          status: 'connected',
          devices: [
            DeviceInfo(serial: 'dev-A', model: 'Device A', authorized: true),
            DeviceInfo(serial: 'dev-B', model: 'Device B', authorized: true),
          ],
          activeDevice: 'dev-A',
        ),
      );

      // Filter dev-A on 'AppA'
      controller.setSearch('AppA');
      controller.setMinLevel('E');

      // Switch to dev-B and filter on 'AppB'
      controller.selectDeviceTab('dev-B');
      controller.setSearch('AppB');
      controller.setMinLevel('D');

      // Switch back to dev-A
      controller.selectDeviceTab('dev-A');
      expect(controller.search, 'AppA');
      expect(controller.minLevel, 'E');

      // Switch back to dev-B
      controller.selectDeviceTab('dev-B');
      expect(controller.search, 'AppB');
      expect(controller.minLevel, 'D');
    });

    testWidgets('5.1 DeviceTabBar renders device list and allows switching', (
      tester,
    ) async {
      String? selected;
      bool toggled = false;

      const devices = [
        DeviceInfo(serial: 'ser-1', model: 'Pixel 6', authorized: true),
        DeviceInfo(serial: 'ser-2', model: 'Pixel 7', authorized: true),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: const [kDarkModernPalette],
          ),
          home: Scaffold(
            body: DeviceTabBar(
              devices: devices,
              activeSerial: 'ser-1',
              viewMode: DeviceViewMode.singleOrTabs,
              onSelectDevice: (s) => selected = s,
              onToggleViewMode: () => toggled = true,
            ),
          ),
        ),
      );

      expect(find.text('Pixel 6'), findsOneWidget);
      expect(find.text('Pixel 7'), findsOneWidget);

      await tester.tap(find.text('Pixel 7'));
      await tester.pump();
      expect(selected, 'ser-2');

      await tester.tap(find.byIcon(Icons.grid_view_rounded));
      await tester.pump();
      expect(toggled, isTrue);
    });

    testWidgets(
      '5.2 & 5.3 MultiScreenGrid enforces 2-stream cap and bulk screenshot',
      (tester) async {
        final mockClient = MockMatrixCaptureClient();
        final captureService = CaptureService(client: mockClient);

        const devices = [
          DeviceInfo(serial: 'd-1', model: 'Device 1', authorized: true),
          DeviceInfo(serial: 'd-2', model: 'Device 2', authorized: true),
          DeviceInfo(serial: 'd-3', model: 'Device 3', authorized: true),
        ];

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: const [kDarkModernPalette],
            ),
            home: Scaffold(
              body: MultiScreenGrid(
                devices: devices,
                captureService: captureService,
                onSelectDevice: (_) {},
              ),
            ),
          ),
        );

        // Verify live cap badge is 2/2
        expect(find.text('Live cap: 2/2'), findsOneWidget);
        expect(find.text('● LIVE'), findsNWidgets(2));
        expect(find.text('Go Live'), findsOneWidget);

        // Trigger "Screenshot All" bulk action (Phase 5.3)
        await tester.tap(find.text('Screenshot All'));
        await tester.pumpAndSettle();

        expect(mockClient.capturedSerials, containsAll(['d-1', 'd-2', 'd-3']));
      },
    );
  });
}
