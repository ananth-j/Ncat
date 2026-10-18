import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/bridge/server/device_session.dart';
import 'package:wcat/bridge/server/runners/process_runner.dart';

void main() {
  group('DeviceSession Manager (T.7)', () {
    late FakeProcessRunner fakeRunner;

    setUp(() {
      fakeRunner = FakeProcessRunner();
    });

    test('Isolated state and buffers across multiple serials', () async {
      final session1 = DeviceSession(
        serial: 'device-1',
        adbPath: 'adb',
        processRunner: fakeRunner,
      );
      final session2 = DeviceSession(
        serial: 'device-2',
        adbPath: 'adb',
        processRunner: fakeRunner,
      );

      // Start logcat on both sessions with mock stdout
      final stdout1 = StreamController<List<int>>();
      final stdout2 = StreamController<List<int>>();

      fakeRunner.onStart('logcat', (args) async {
        final isDev1 = args.contains('device-1');
        return FakeProcess(
          stdoutStream: isDev1 ? stdout1.stream : stdout2.stream,
        );
      });

      await session1.startLogcat();
      await session2.startLogcat();

      // Emit log lines to session 1
      stdout1.add(
        utf8.encode('10-18 10:00:00.000 100 100 I TagA: Hello from device 1\n'),
      );
      await pumpEventQueue();

      // Emit log lines to session 2
      stdout2.add(
        utf8.encode('10-18 10:00:01.000 200 200 I TagB: Hello from device 2\n'),
      );
      await pumpEventQueue();

      final batch1 = session1.flushPending();
      final batch2 = session2.flushPending();

      // Each batch includes the initial system message and the incoming log line
      expect(batch1.length, 2);
      expect(batch1.first['tag'], 'bridge');
      expect(batch1.last['serial'], 'device-1');
      expect(batch1.last['tag'], 'TagA');

      expect(batch2.length, 2);
      expect(batch2.first['tag'], 'bridge');
      expect(batch2.last['serial'], 'device-2');
      expect(batch2.last['tag'], 'TagB');

      expect(session1.history.length, 2);
      expect(session2.history.length, 2);

      await session1.dispose();
      await session2.dispose();
    });

    test('Buffer caps strictly at kHistorySize (3,000) per session', () async {
      final session = DeviceSession(
        serial: 'device-test',
        adbPath: 'adb',
        processRunner: fakeRunner,
      );

      final stdout = StreamController<List<int>>();
      fakeRunner.onStart('logcat', (args) async {
        return FakeProcess(stdoutStream: stdout.stream);
      });

      await session.startLogcat();

      // Ingest 3,500 lines
      final buffer = StringBuffer();
      for (int i = 0; i < 3500; i++) {
        buffer.writeln('10-18 10:00:00.000 100 100 I Tag: Log message $i');
      }
      stdout.add(utf8.encode(buffer.toString()));
      await pumpEventQueue();

      session.flushPending();
      expect(session.history.length, kHistorySize);

      await session.dispose();
    });

    test('dispose() terminates logcat and cleans up device orphans', () async {
      final session = DeviceSession(
        serial: 'device-cleanup',
        adbPath: 'adb',
        processRunner: fakeRunner,
      );

      final fakeProc = FakeProcess();
      fakeRunner.onStart('logcat', (args) async => fakeProc);

      await session.startLogcat();
      expect(fakeProc.isKilled, isFalse);

      await session.dispose();

      expect(fakeProc.isKilled, isTrue);

      // Verify SIGINT / pkill and rm were executed
      final calls = fakeRunner.calls.map((c) => c.toString()).toList();
      expect(
        calls.any((c) => c.contains('pkill -2 screenrecord')),
        isTrue,
        reason: 'Must send SIGINT to screenrecord on device during cleanup',
      );
      expect(
        calls.any((c) => c.contains('rm -f /sdcard/wcat_*.mp4')),
        isTrue,
        reason: 'Must clean up temporary recording files',
      );
    });
  });
}
