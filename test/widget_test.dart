import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wcat/main.dart';

void main() {
  test('LogEntry.fromJson parses a server payload', () {
    final entry = LogEntry.fromJson({
      'seq': 1,
      'time': '09-01 14:22:31.123',
      'pid': 4521,
      'tid': 4530,
      'level': 'W',
      'tag': 'MyTag',
      'msg': 'the message',
    });

    expect(entry.pid, 4521);
    expect(entry.tid, 4530);
    expect(entry.level, 'W');
    expect(entry.tag, 'MyTag');
    expect(entry.msg, 'the message');
  });

  test('LogEntry.rank orders severity from V to F', () {
    LogEntry level(String l) => LogEntry.fromJson({
          'seq': 0,
          'time': '',
          'pid': 0,
          'tid': 0,
          'level': l,
          'tag': '',
          'msg': '',
        });

    expect(level('V').rank, lessThan(level('D').rank));
    expect(level('D').rank, lessThan(level('I').rank));
    expect(level('I').rank, lessThan(level('W').rank));
    expect(level('W').rank, lessThan(level('E').rank));
    expect(level('E').rank, lessThan(level('F').rank));
  });

  test('DeviceInfo.label displays model, serial, and unauthorized status', () {
    const authorizedWithModel = DeviceInfo(serial: 'ABC1234', model: 'Pixel 8');
    expect(authorizedWithModel.label, 'Pixel 8 (ABC1234)');

    const authorizedNoModel = DeviceInfo(serial: 'ABC1234');
    expect(authorizedNoModel.label, 'ABC1234');

    const unauthorized = DeviceInfo(serial: 'ABC1234', authorized: false);
    expect(unauthorized.label, 'ABC1234 [Unauthorized]');
  });

  test('LogEntry parses pkg field from server payload', () {
    final entry = LogEntry.fromJson({
      'seq': 2,
      'time': '10-04 19:45:12.345',
      'pid': 1024,
      'tid': 1024,
      'level': 'I',
      'tag': 'MainActivity',
      'msg': 'Hello World',
      'pkg': 'com.example.myapp',
    });

    expect(entry.pkg, 'com.example.myapp');
  });

  test('LogColumnConfig presets and copyWith toggle visibility', () {
    const standard = LogColumnConfig.standard;
    expect(standard.showTime, isTrue);
    expect(standard.showPidTid, isTrue);
    expect(standard.showPackage, isTrue);
    expect(standard.showLevel, isTrue);
    expect(standard.showTag, isTrue);

    const messageOnly = LogColumnConfig.messageOnly;
    expect(messageOnly.showTime, isFalse);
    expect(messageOnly.showPidTid, isFalse);
    expect(messageOnly.showPackage, isFalse);
    expect(messageOnly.showLevel, isFalse);
    expect(messageOnly.showTag, isFalse);

    final custom = standard.copyWith(showTime: false, showPidTid: false);
    expect(custom.showTime, isFalse);
    expect(custom.showPidTid, isFalse);
    expect(custom.showPackage, isTrue);
    expect(custom.showLevel, isTrue);
    expect(custom.showTag, isTrue);
  });

  test('buildAppTheme builds ThemeData with AppPalette extension', () {
    final lightTheme = buildAppTheme(Brightness.light, kLightPalette);
    expect(lightTheme.brightness, Brightness.light);
    expect(lightTheme.extension<AppPalette>(), equals(kLightPalette));

    final darkTheme = buildAppTheme(Brightness.dark, kDarkModernPalette);
    expect(darkTheme.brightness, Brightness.dark);
    expect(darkTheme.extension<AppPalette>(), equals(kDarkModernPalette));
  });

  testWidgets('DropdownButton renders device items without unbounded width error', (tester) async {
    const devices = [
      DeviceInfo(serial: 'ROHQDY59QSG6EM6H', model: 'RMX3870'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark, kDarkModernPalette),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 220,
              child: DropdownButton<String?>(
                value: 'ROHQDY59QSG6EM6H',
                items: [
                  for (final d in devices)
                    DropdownMenuItem<String?>(
                      value: d.serial,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 150),
                            child: Text(d.label, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: null,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('RMX3870 (ROHQDY59QSG6EM6H)'), findsOneWidget);
  });
}
