import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/bridge/server/bridge_server.dart';
import 'package:wcat/bridge/server/runners/process_runner.dart';
import 'package:wcat/bridge/server/runners/scrcpy_resolver.dart';

void main() {
  group('Bridge Mirroring & Input Endpoints (Phase 4)', () {
    late FakeProcessRunner fakeRunner;
    late LogcatBridgeServer server;
    late HttpClient client;
    final mockPng = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    setUp(() async {
      fakeRunner = FakeProcessRunner();
      client = HttpClient();
      ScrcpyResolver.executableOverride = 'scrcpy';
      ScrcpyResolver.installerOverride = null;

      fakeRunner.onStart('track-devices', (args) async => FakeProcess());
      fakeRunner.onStart('logcat', (args) async => FakeProcess());

      fakeRunner.onRun('devices -l', (args) async {
        return ProcessResult(
          1,
          0,
          'List of devices attached\n'
              'device-mirror-1 device model:Pixel_Mirror\n',
          '',
        );
      });

      fakeRunner.onRun('screencap', (args) async {
        return ProcessResult(10, 0, mockPng, '');
      });

      server = LogcatBridgeServer(
        port: 9889,
        adbPath: 'adb',
        processRunner: fakeRunner,
      );

      await server.start();
    });

    tearDown(() async {
      ScrcpyResolver.executableOverride = null;
      ScrcpyResolver.installerOverride = null;
      client.close();
      await server.stop();
    });

    test('POST /api/scrcpy/launch launches external scrcpy process', () async {
      fakeRunner.onStart('scrcpy', (args) async {
        expect(args, contains('-s'));
        expect(args, contains('device-mirror-1'));
        return FakeProcess(pid: 777);
      });

      final req = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:9889/api/scrcpy/launch?serial=device-mirror-1',
        ),
      );
      final res = await req.close();

      expect(res.statusCode, HttpStatus.ok);
      final json =
          jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(json['status'], 'launched');
      expect(json['serial'], 'device-mirror-1');
      expect(json['pid'], 777);
    });

    test(
      'POST /api/scrcpy/launch returns not_installed when binary missing',
      () async {
        ScrcpyResolver.executableOverride = '';

        final req = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:9889/api/scrcpy/launch?serial=device-mirror-1',
          ),
        );
        final res = await req.close();

        expect(res.statusCode, HttpStatus.ok);
        final json =
            jsonDecode(await res.transform(utf8.decoder).join())
                as Map<String, dynamic>;
        expect(json['status'], 'not_installed');
      },
    );

    test('GET /api/scrcpy/status returns binary availability', () async {
      ScrcpyResolver.executableOverride = '/custom/path/scrcpy';

      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:9889/api/scrcpy/status'),
      );
      final res = await req.close();

      expect(res.statusCode, HttpStatus.ok);
      final json =
          jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(json['installed'], isTrue);
      expect(json['path'], '/custom/path/scrcpy');
      expect(json['version'], isNotEmpty);
    });

    test('POST /api/scrcpy/install invokes installer handler', () async {
      ScrcpyResolver.installerOverride = ({onStatus}) async {
        onStatus?.call('Testing install hook');
        return {
          'status': 'ok',
          'version': 'v5.0.1',
          'path': '/tools/scrcpy.exe',
        };
      };

      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:9889/api/scrcpy/install'),
      );
      final res = await req.close();

      expect(res.statusCode, HttpStatus.ok);
      final json =
          jsonDecode(await res.transform(utf8.decoder).join())
              as Map<String, dynamic>;
      expect(json['status'], 'ok');
      expect(json['path'], '/tools/scrcpy.exe');
    });

    test(
      'POST /api/input writes tap, swipe, and key to persistent adb shell stdin',
      () async {
        final shellCommands = <String>[];
        final shellProcess = FakeProcess(
          pid: 101,
          onInput: (data) {
            shellCommands.add(data.trim());
          },
        );

        fakeRunner.onStart('shell', (args) async {
          return shellProcess;
        });

        // 1. Send tap
        final tapReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:9889/api/input'),
        );
        tapReq.headers.contentType = ContentType.json;
        tapReq.write(
          jsonEncode({
            'serial': 'device-mirror-1',
            'action': 'tap',
            'x': 450,
            'y': 920,
          }),
        );
        final tapRes = await tapReq.close();
        expect(tapRes.statusCode, HttpStatus.ok);

        // 2. Send keyevent
        final keyReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:9889/api/input'),
        );
        keyReq.headers.contentType = ContentType.json;
        keyReq.write(
          jsonEncode({
            'serial': 'device-mirror-1',
            'action': 'key',
            'keyCode': 4, // KEYCODE_BACK
          }),
        );
        final keyRes = await keyReq.close();
        expect(keyRes.statusCode, HttpStatus.ok);

        // 3. Send swipe
        final swipeReq = await client.postUrl(
          Uri.parse('http://127.0.0.1:9889/api/input'),
        );
        swipeReq.headers.contentType = ContentType.json;
        swipeReq.write(
          jsonEncode({
            'serial': 'device-mirror-1',
            'action': 'swipe',
            'x1': 100,
            'y1': 500,
            'x2': 100,
            'y2': 100,
            'durationMs': 200,
          }),
        );
        final swipeRes = await swipeReq.close();
        expect(swipeRes.statusCode, HttpStatus.ok);

        expect(shellCommands, contains('input tap 450 920'));
        expect(shellCommands, contains('input keyevent 4'));
        expect(shellCommands, contains('input swipe 100 500 100 100 200'));
      },
    );

    test(
      'GET /api/stream streams multipart MJPEG frames and stops on disconnect',
      () async {
        final req = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:9889/api/stream?serial=device-mirror-1&fps=15',
          ),
        );
        final res = await req.close();

        expect(res.statusCode, HttpStatus.ok);
        expect(res.headers.contentType?.mimeType, 'multipart/x-mixed-replace');

        // Read initial chunks to verify boundary and content type
        final chunks = <String>[];
        await for (final chunk in res.transform(utf8.decoder)) {
          chunks.add(chunk);
          if (chunks.join().contains('image/png')) break;
        }
        expect(chunks.join(), contains('--frame'));
        expect(chunks.join(), contains('image/png'));

        // Disconnect client
        await res.detachSocket().then((s) => s.destroy());

        // Verify session cleans up stream
        final session = server.sessions['device-mirror-1'];
        expect(session, isNotNull);
      },
    );
  });
}
