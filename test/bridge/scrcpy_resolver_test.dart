import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/bridge/server/runners/scrcpy_resolver.dart';

void main() {
  group('ScrcpyResolver Unit Tests', () {
    tearDown(() {
      ScrcpyResolver.executableOverride = null;
      ScrcpyResolver.installerOverride = null;
    });

    test('getLocalScrcpyDir resolves platform-specific path', () {
      final dir = ScrcpyResolver.getLocalScrcpyDir();
      expect(dir.path, isNotEmpty);
      expect(
        dir.path,
        anyOf(
          contains('${Platform.pathSeparator}scrcpy'),
          contains('/scrcpy'),
          contains(r'\scrcpy'),
        ),
      );
    });

    test(
      'getDownloadUrl returns official GitHub release asset for host OS',
      () {
        final url = ScrcpyResolver.getDownloadUrl();
        expect(url, isNotNull);
        expect(
          url,
          contains(
            'https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/',
          ),
        );
        if (Platform.isWindows) {
          expect(url, endsWith('.zip'));
          expect(url, contains('win64'));
        } else if (Platform.isMacOS) {
          expect(url, endsWith('.tar.gz'));
          expect(url, contains('macos'));
        } else if (Platform.isLinux) {
          expect(url, endsWith('.tar.gz'));
          expect(url, contains('linux'));
        }
      },
    );

    test('findScrcpyExecutable returns executableOverride when provided', () {
      ScrcpyResolver.executableOverride = r'C:\custom\bin\scrcpy.exe';
      expect(
        ScrcpyResolver.findScrcpyExecutable(),
        r'C:\custom\bin\scrcpy.exe',
      );
    });

    test(
      'installScrcpy uses installerOverride and notifies progress',
      () async {
        final logs = <String>[];
        ScrcpyResolver.installerOverride = ({onStatus}) async {
          onStatus?.call('Downloading package...');
          onStatus?.call('Extracting files...');
          return {
            'status': 'ok',
            'version': 'v5.0.1',
            'path': r'C:\tools\scrcpy\scrcpy.exe',
          };
        };

        final res = await ScrcpyResolver.installScrcpy(
          onStatus: (msg) => logs.add(msg),
        );

        expect(res['status'], 'ok');
        expect(res['path'], r'C:\tools\scrcpy\scrcpy.exe');
        expect(logs, contains('Downloading package...'));
        expect(logs, contains('Extracting files...'));
      },
    );
  });
}
