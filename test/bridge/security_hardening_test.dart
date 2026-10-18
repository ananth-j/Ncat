import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/bridge/server/bridge_server.dart';
import 'package:wcat/bridge/server/device_session.dart';
import 'package:wcat/bridge/server/runners/process_runner.dart';

void main() {
  group('Security Hardening (Phase 6.1)', () {
    test(
      'DeviceSession.isValidSerial validates safe formats and rejects flag injection',
      () {
        // Valid serials
        expect(DeviceSession.isValidSerial('emulator-5554'), isTrue);
        expect(DeviceSession.isValidSerial('192.168.1.50:5555'), isTrue);
        expect(DeviceSession.isValidSerial('RF8M10ABCDE'), isTrue);
        expect(DeviceSession.isValidSerial('device_123.test'), isTrue);

        // Invalid serials (flag injection, command injection, path traversal, shell metacharacters)
        expect(DeviceSession.isValidSerial('-s'), isFalse);
        expect(DeviceSession.isValidSerial('--all'), isFalse);
        expect(DeviceSession.isValidSerial('-d'), isFalse);
        expect(DeviceSession.isValidSerial('device; rm -rf /'), isFalse);
        expect(DeviceSession.isValidSerial('device & touch /tmp/pwn'), isFalse);
        expect(DeviceSession.isValidSerial('device`id`'), isFalse);
        expect(DeviceSession.isValidSerial('device\nid'), isFalse);
        expect(DeviceSession.isValidSerial('device with spaces'), isFalse);
        expect(DeviceSession.isValidSerial(''), isFalse);
        expect(
          DeviceSession.isValidSerial('a' * 65),
          isFalse,
        ); // exceeds max length

        // Constructor enforces serial format validation
        expect(
          () => DeviceSession(serial: '-malicious-flag', adbPath: 'adb'),
          throwsArgumentError,
        );
      },
    );

    test(
      'sendInputText strips newlines, null bytes and escapes single quotes for POSIX shell',
      () async {
        final fakeRunner = FakeProcessRunner();
        final stdinWritten = <String>[];

        fakeRunner.onStart('shell', (args) async {
          return FakeProcess(onInput: (data) => stdinWritten.add(data));
        });

        final session = DeviceSession(
          serial: 'valid-device-1',
          adbPath: 'adb',
          processRunner: fakeRunner,
        );

        // 1. Text with spaces and punctuation
        await session.sendInputText('Hello World');
        expect(stdinWritten.last, contains("input text 'Hello%sWorld'\n"));

        // 2. Text containing single quotes and double quotes
        await session.sendInputText("Don't panic \"now\"");
        expect(
          stdinWritten.last,
          contains(
            r"input text 'Don'\''t%spanic%s"
            '"now"'
            "'\n",
          ),
        );

        // 3. Text with newline and command injection attempts
        await session.sendInputText("test\nrm -rf /\r\x00; reboot");
        expect(stdinWritten.last, isNot(contains('\nrm')));
        expect(stdinWritten.last, isNot(contains('\r')));
        expect(stdinWritten.last, isNot(contains('\x00')));
        // The newlines and nulls are stripped, remaining text is safe inside single quotes
        expect(
          stdinWritten.last,
          contains("input text 'testrm%s-rf%s/;%sreboot'\n"),
        );
      },
    );

    group('LogcatBridgeServer security policies', () {
      late FakeProcessRunner fakeRunner;
      late LogcatBridgeServer server;
      late HttpClient client;
      const testPort = 9895;
      const secretToken = 'sec-token-abc-xyz-123';

      setUp(() async {
        fakeRunner = FakeProcessRunner();
        client = HttpClient();

        fakeRunner.onStart('track-devices', (args) async => FakeProcess());
        fakeRunner.onStart('logcat', (args) async => FakeProcess());
        fakeRunner.onRun('devices -l', (args) async {
          return ProcessResult(
            1,
            0,
            'List of devices attached\nvalid-dev device model:Pixel\n',
            '',
          );
        });
        fakeRunner.onRun('screencap', (args) async {
          return ProcessResult(10, 0, [0x89, 0x50, 0x4E, 0x47], '');
        });

        server = LogcatBridgeServer(
          port: testPort,
          adbPath: 'adb',
          processRunner: fakeRunner,
          authToken: secretToken,
          requireAuth: true,
        );

        await server.start();
      });

      tearDown(() async {
        client.close();
        await server.stop();
      });

      test(
        'Origin validation blocks external origins with 403 Forbidden',
        () async {
          // Request from malicious external origin
          final req = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:$testPort/api/screenshot?serial=valid-dev',
            ),
          );
          req.headers.set('Origin', 'https://malicious-website.com');
          final res = await req.close();

          expect(res.statusCode, HttpStatus.forbidden);
          final body = await utf8.decoder.bind(res).join();
          expect(body, contains('Forbidden: Invalid Origin'));
        },
      );

      test(
        'Token authentication rejects unauthenticated or invalid requests with 401 Unauthorized',
        () async {
          // 1. No token provided
          final req1 = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:$testPort/api/screenshot?serial=valid-dev',
            ),
          );
          req1.headers.set('Origin', 'http://localhost');
          final res1 = await req1.close();
          expect(res1.statusCode, HttpStatus.unauthorized);

          // 2. Wrong token provided
          final req2 = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:$testPort/api/screenshot?serial=valid-dev&token=wrong',
            ),
          );
          req2.headers.set('Origin', 'http://localhost');
          final res2 = await req2.close();
          expect(res2.statusCode, HttpStatus.unauthorized);

          // 3. Valid token in query parameter
          final req3 = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:$testPort/api/screenshot?serial=valid-dev&token=$secretToken',
            ),
          );
          req3.headers.set('Origin', 'http://localhost');
          final res3 = await req3.close();
          expect(res3.statusCode, HttpStatus.ok);

          // 4. Valid token in X-Auth-Token header
          final req4 = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:$testPort/api/screenshot?serial=valid-dev',
            ),
          );
          req4.headers.set('Origin', 'http://localhost');
          req4.headers.set('X-Auth-Token', secretToken);
          final res4 = await req4.close();
          expect(res4.statusCode, HttpStatus.ok);

          // 5. Valid token in Authorization: Bearer header
          final req5 = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:$testPort/api/screenshot?serial=valid-dev',
            ),
          );
          req5.headers.set('Origin', 'http://localhost');
          req5.headers.set('Authorization', 'Bearer $secretToken');
          final res5 = await req5.close();
          expect(res5.statusCode, HttpStatus.ok);
        },
      );

      test(
        'HTTP endpoints reject malicious device serial format with 400 Bad Request',
        () async {
          // Flag injection attempt
          final req1 = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:$testPort/api/screenshot?serial=-s&token=$secretToken',
            ),
          );
          req1.headers.set('Origin', 'http://localhost');
          final res1 = await req1.close();
          expect(res1.statusCode, HttpStatus.badRequest);
          final body1 = await utf8.decoder.bind(res1).join();
          expect(body1, contains('Invalid device serial format'));

          // Command injection attempt in record endpoint
          final req2 = await client.postUrl(
            Uri.parse(
              'http://127.0.0.1:$testPort/api/record/start?serial=device;rm&token=$secretToken',
            ),
          );
          req2.headers.set('Origin', 'http://localhost');
          final res2 = await req2.close();
          expect(res2.statusCode, HttpStatus.badRequest);
          final body2 = await utf8.decoder.bind(res2).join();
          expect(body2, contains('Invalid device serial format'));
        },
      );
    });
  });
}
