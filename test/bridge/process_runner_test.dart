import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/bridge/server/bridge_server.dart';
import 'package:wcat/bridge/server/runners/adb_tracker.dart';
import 'package:wcat/bridge/server/runners/process_runner.dart';

void main() {
  group('Bridge Process & Tracker Tests (T.6)', () {
    late FakeProcessRunner fakeRunner;

    setUp(() {
      fakeRunner = FakeProcessRunner();
    });

    test(
      'AdbTracker parses streaming device changes and reconnects on exit',
      () async {
        final trackStdout = StreamController<List<int>>();
        final trackProc = FakeProcess(stdoutStream: trackStdout.stream);

        fakeRunner.onStart('track-devices', (args) async => trackProc);

        fakeRunner.onRun('devices -l', (args) async {
          return ProcessResult(
            1,
            0,
            'List of devices attached\n'
                'emulator-5554 device product:sdk_gphone64 model:Pixel_6 transport_id:1\n',
            '',
          );
        });

        List<AdbDeviceEntry>? lastDevices;
        final tracker = AdbTracker(
          adbPath: 'adb',
          processRunner: fakeRunner,
          onDevicesChanged: (devs) {
            lastDevices = devs;
          },
        );

        await tracker.start();
        await pumpEventQueue();

        expect(lastDevices, isNotNull);
        expect(lastDevices!.length, 1);
        expect(lastDevices!.first.serial, 'emulator-5554');
        expect(lastDevices!.first.model, 'Pixel_6');
        expect(lastDevices!.first.isAuthorized, isTrue);

        // Simulate a device update from track-devices stream
        fakeRunner.onRun('devices -l', (args) async {
          return ProcessResult(
            2,
            0,
            'List of devices attached\n'
                'emulator-5554 device product:sdk_gphone64 model:Pixel_6 transport_id:1\n'
                'physical-phone unauthorized transport_id:2\n',
            '',
          );
        });

        trackStdout.add(
          utf8.encode('emulator-5554 device\nphysical-phone unauthorized\n'),
        );
        await pumpEventQueue();

        expect(lastDevices!.length, 2);
        expect(
          lastDevices!.any(
            (d) => d.serial == 'physical-phone' && !d.isAuthorized,
          ),
          isTrue,
        );

        await tracker.stop();
        expect(trackProc.isKilled, isTrue);
      },
    );

    test(
      'Bridge server binds loopback 127.0.0.1 and cleans up on stop',
      () async {
        final trackStdout = StreamController<List<int>>();
        final trackProc = FakeProcess(stdoutStream: trackStdout.stream);

        fakeRunner.onStart('track-devices', (args) async => trackProc);
        fakeRunner.onStart('logcat', (args) async => FakeProcess());

        fakeRunner.onRun('devices -l', (args) async {
          return ProcessResult(
            1,
            0,
            'List of devices attached\n'
                'emu-5554 device model:Emu\n',
            '',
          );
        });

        final server = LogcatBridgeServer(
          port: 9876,
          adbPath: 'adb',
          processRunner: fakeRunner,
        );

        final started = await server.start();
        expect(started, isTrue);

        expect(server.activeSerial, 'emu-5554');
        expect(server.sessions.containsKey('emu-5554'), isTrue);

        await server.stop();
        expect(server.sessions.isEmpty, isTrue);
        expect(trackProc.isKilled, isTrue);
      },
    );

    test(
      'Device disconnect cleans up session and dispatches orphan cleanup',
      () async {
        final trackStdout = StreamController<List<int>>();
        final trackProc = FakeProcess(stdoutStream: trackStdout.stream);

        fakeRunner.onStart('track-devices', (args) async => trackProc);
        fakeRunner.onStart('logcat', (args) async => FakeProcess());

        fakeRunner.onRun('devices -l', (args) async {
          return ProcessResult(
            1,
            0,
            'List of devices attached\n'
                'emu-1234 device model:Pixel\n',
            '',
          );
        });

        final server = LogcatBridgeServer(
          port: 9877,
          adbPath: 'adb',
          processRunner: fakeRunner,
        );

        await server.start();
        expect(server.sessions.containsKey('emu-1234'), isTrue);

        // Now simulate device unplugged
        fakeRunner.onRun('devices -l', (args) async {
          return ProcessResult(2, 0, 'List of devices attached\n', '');
        });

        trackStdout.add(utf8.encode('\n'));
        for (int i = 0; i < 10; i++) {
          await pumpEventQueue();
        }

        expect(server.sessions.containsKey('emu-1234'), isFalse);

        final calls = fakeRunner.calls.map((c) => c.toString()).toList();
        expect(
          calls.any((c) => c.contains('pkill -2 screenrecord')),
          isTrue,
          reason: 'Disconnect must trigger orphan screenrecord cleanup',
        );

        await server.stop();
      },
    );
  });
}
