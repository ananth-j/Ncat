import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/bridge/server/bridge_server.dart';
import 'package:wcat/bridge/server/runners/process_runner.dart';

void main() {
  group('Bridge Screenshot & Recording Endpoints (Phase 3)', () {
    late FakeProcessRunner fakeRunner;
    late LogcatBridgeServer server;
    late HttpClient client;

    setUp(() async {
      fakeRunner = FakeProcessRunner();
      client = HttpClient();

      fakeRunner.onStart('track-devices', (args) async => FakeProcess());
      fakeRunner.onStart('logcat', (args) async => FakeProcess());

      fakeRunner.onRun('devices -l', (args) async {
        return ProcessResult(
          1,
          0,
          'List of devices attached\n'
              'device-rec-1 device model:Pixel_Test\n',
          '',
        );
      });

      server = LogcatBridgeServer(
        port: 9888,
        adbPath: 'adb',
        processRunner: fakeRunner,
      );

      await server.start();
    });

    tearDown(() async {
      client.close();
      await server.stop();
    });

    test('GET /api/screenshot returns raw PNG bytes', () async {
      final mockPng = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      fakeRunner.onRun('screencap', (args) async {
        return ProcessResult(10, 0, mockPng, '');
      });

      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:9888/api/screenshot?serial=device-rec-1'),
      );
      final res = await req.close();

      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, 'image/png');

      final body = <int>[];
      await for (final chunk in res) {
        body.addAll(chunk);
      }
      expect(body, mockPng);
    });

    test(
      'POST /api/record/start and stop executes device screenrecord with SIGINT',
      () async {
        final screenrecordProcess = FakeProcess();
        fakeRunner.onStart('screenrecord', (args) async => screenrecordProcess);

        // 1. Start recording
        final startReq = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:9888/api/record/start?serial=device-rec-1',
          ),
        );
        final startRes = await startReq.close();

        expect(startRes.statusCode, HttpStatus.ok);
        final startJson =
            jsonDecode(await startRes.transform(utf8.decoder).join())
                as Map<String, dynamic>;
        expect(startJson['status'], 'recording');
        expect(startJson['serial'], 'device-rec-1');

        // Verify screenrecord process was spawned with correct arguments
        final startCalls = fakeRunner.calls.map((c) => c.toString()).toList();
        expect(
          startCalls.any(
            (c) => c.contains('screenrecord') && c.contains('/sdcard/wcat_'),
          ),
          isTrue,
          reason: 'Must spawn screenrecord on device with unique filename',
        );

        // Setup fake responses for stop sequence
        fakeRunner.onRun('pkill -2 screenrecord', (args) async {
          screenrecordProcess.completeExit(0);
          return ProcessResult(1, 0, '', '');
        });
        fakeRunner.onRun('pull', (args) async {
          // Create the dummy local temp file that adb pull would create
          final tempPath = args.last;
          final file = File(tempPath);
          await file.writeAsBytes([
            0x00,
            0x00,
            0x00,
            0x20,
            0x66,
            0x74,
            0x79,
            0x70,
          ]);
          return ProcessResult(2, 0, '1 file pulled', '');
        });
        fakeRunner.onRun('rm -f', (args) async => ProcessResult(3, 0, '', ''));

        // 2. Stop recording
        final stopReq = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:9888/api/record/stop?serial=device-rec-1',
          ),
        );
        final stopRes = await stopReq.close();

        expect(stopRes.statusCode, HttpStatus.ok);
        expect(stopRes.headers.contentType?.mimeType, 'video/mp4');

        final mp4Bytes = <int>[];
        await for (final chunk in stopRes) {
          mp4Bytes.addAll(chunk);
        }
        expect(mp4Bytes, [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70]);

        // Verify SIGINT and cleanup sequence
        final allCalls = fakeRunner.calls.map((c) => c.toString()).toList();
        expect(
          allCalls.any((c) => c.contains('pkill -2 screenrecord')),
          isTrue,
          reason: 'Stop must send SIGINT (signal 2) on device',
        );
        expect(
          allCalls.any(
            (c) =>
                c.contains('pull') && c.contains('/sdcard/wcat_device-rec-1_'),
          ),
          isTrue,
          reason: 'Stop must pull the recording from device',
        );
        expect(
          allCalls.any(
            (c) =>
                c.contains('rm -f') && c.contains('/sdcard/wcat_device-rec-1_'),
          ),
          isTrue,
          reason: 'Stop must clean up temporary recording on device',
        );
      },
    );
  });
}
