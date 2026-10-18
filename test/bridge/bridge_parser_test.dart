import 'package:flutter_test/flutter_test.dart';

void main() {
  final logRe = RegExp(
    r'^(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEFS])\s+(.*?)\s*: ?(.*)$',
  );

  group('Bridge Logcat Regex Parser', () {
    test('parses standard threadtime logcat format', () {
      const line =
          '10-18 09:15:22.456  1234  5678 I ActivityManager: Displayed com.example.app/.MainActivity: +240ms';

      final match = logRe.firstMatch(line);
      expect(match, isNotNull);
      expect(match!.group(1), '10-18 09:15:22.456');
      expect(match.group(2), '1234');
      expect(match.group(3), '5678');
      expect(match.group(4), 'I');
      expect(match.group(5), 'ActivityManager');
      expect(match.group(6), 'Displayed com.example.app/.MainActivity: +240ms');
    });

    test('parses error line with assert level F', () {
      const line =
          '01-01 00:00:01.000   999   999 F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR)';

      final match = logRe.firstMatch(line);
      expect(match, isNotNull);
      expect(match!.group(4), 'F');
      expect(match.group(5), 'libc');
      expect(match.group(6),
          'Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR)');
    });

    test('parses log line with tag containing symbols or dots', () {
      const line =
          '05-12 14:30:10.999  4321  4321 D okhttp.OkHttpClient: <-- 200 OK https://api.example.com (45ms)';

      final match = logRe.firstMatch(line);
      expect(match, isNotNull);
      expect(match!.group(4), 'D');
      expect(match.group(5), 'okhttp.OkHttpClient');
      expect(match.group(6), '<-- 200 OK https://api.example.com (45ms)');
    });

    test('returns null for non-logcat lines (e.g. system messages)', () {
      const systemLine = '--------- beginning of main';
      expect(logRe.firstMatch(systemLine), isNull);

      const adbOutput = 'List of devices attached';
      expect(logRe.firstMatch(adbOutput), isNull);
    });
  });

  group('Bridge ADB Devices Output Parsing', () {
    List<Map<String, dynamic>> parseDevicesOutput(String stdout) {
      final devices = <Map<String, dynamic>>[];
      for (final line in stdout.split('\n').skip(1)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;

        final state = parts[1];
        if (state == 'unauthorized') {
          devices.add({
            'serial': parts[0],
            'model': 'Unauthorized (Accept USB debugging)',
            'authorized': false,
          });
          continue;
        }
        if (state == 'offline') {
          devices.add({
            'serial': parts[0],
            'model': 'Offline',
            'authorized': false,
          });
          continue;
        }
        if (state != 'device') continue;

        String? model;
        for (final p in parts.skip(2)) {
          if (p.startsWith('model:')) model = p.substring(6);
        }
        devices.add({'serial': parts[0], 'model': model, 'authorized': true});
      }
      return devices;
    }

    test('parses authorized device with model', () {
      const stdout = '''List of devices attached
ROHQDY59QSG6EM6H       device product:RMX3870 model:RMX3870 device:RMX3870 transport_id:1
''';
      final devices = parseDevicesOutput(stdout);
      expect(devices.length, 1);
      expect(devices.first['serial'], 'ROHQDY59QSG6EM6H');
      expect(devices.first['model'], 'RMX3870');
      expect(devices.first['authorized'], isTrue);
    });

    test('parses unauthorized device', () {
      const stdout = '''List of devices attached
192.168.1.50:5555      unauthorized transport_id:2
''';
      final devices = parseDevicesOutput(stdout);
      expect(devices.length, 1);
      expect(devices.first['serial'], '192.168.1.50:5555');
      expect(devices.first['authorized'], isFalse);
      expect(devices.first['model'], contains('Unauthorized'));
    });

    test('parses offline emulator', () {
      const stdout = '''List of devices attached
emulator-5554          offline transport_id:3
''';
      final devices = parseDevicesOutput(stdout);
      expect(devices.length, 1);
      expect(devices.first['serial'], 'emulator-5554');
      expect(devices.first['authorized'], isFalse);
      expect(devices.first['model'], 'Offline');
    });

    test('handles empty device list', () {
      const stdout = '''List of devices attached

''';
      final devices = parseDevicesOutput(stdout);
      expect(devices, isEmpty);
    });
  });
}
