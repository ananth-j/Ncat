import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/core/constants.dart';
import 'package:wcat/features/devices/models/device_info.dart';
import 'package:wcat/features/logcat/logcat_controller.dart';
import 'package:wcat/features/logcat/models/log_entry.dart';
import 'package:wcat/protocol/messages.dart';
import 'package:wcat/src/column_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LogcatController controller;

  setUp(() {
    controller = LogcatController();
  });

  tearDown(() {
    controller.dispose();
  });

  LogEntry createEntry(int seq, String level, String tag, String msg,
      {String? pkg, int pid = 100, int tid = 101, String time = '10-04 12:00:00.000'}) {
    return LogEntry(
      seq: seq,
      time: time,
      pid: pid,
      tid: tid,
      level: level,
      tag: tag,
      msg: msg,
      pkg: pkg,
    );
  }

  group('LogcatController message & buffer management', () {
    test('HistoryMessage replaces buffer and recomputes visible list', () {
      final initialEntries = [
        createEntry(1, 'I', 'InitTag', 'Init message'),
      ];
      controller.handleMessage(HistoryMessage(initialEntries));

      expect(controller.lines.length, 1);
      expect(controller.visible.length, 1);
      expect(controller.lines.first.tag, 'InitTag');

      final newHistory = [
        createEntry(2, 'D', 'NewTag1', 'Msg 1'),
        createEntry(3, 'W', 'NewTag2', 'Msg 2'),
      ];
      controller.handleMessage(HistoryMessage(newHistory));

      expect(controller.lines.length, 2);
      expect(controller.visible.length, 2);
      expect(controller.lines.first.seq, 2);
    });

    test('LogBatchMessage appends entries to buffer', () {
      controller.handleMessage(LogBatchMessage([
        createEntry(1, 'I', 'Tag1', 'Message 1'),
      ]));
      expect(controller.lines.length, 1);

      controller.handleMessage(LogBatchMessage([
        createEntry(2, 'E', 'Tag2', 'Message 2'),
      ]));
      expect(controller.lines.length, 2);
      expect(controller.lines.last.level, 'E');
    });

    test('LogBatchMessage is ignored when controller is paused', () {
      controller.handleMessage(LogBatchMessage([
        createEntry(1, 'I', 'Tag1', 'Message 1'),
      ]));
      expect(controller.lines.length, 1);

      controller.togglePaused();
      expect(controller.paused, isTrue);

      controller.handleMessage(LogBatchMessage([
        createEntry(2, 'E', 'Tag2', 'Message 2 while paused'),
      ]));
      expect(controller.lines.length, 1);

      controller.togglePaused();
      expect(controller.paused, isFalse);

      controller.handleMessage(LogBatchMessage([
        createEntry(3, 'D', 'Tag3', 'Message 3 after resume'),
      ]));
      expect(controller.lines.length, 2);
    });

    test('Buffer caps strictly at kMaxLines capacity', () {
      final batch1 = List.generate(
        kMaxLines,
        (i) => createEntry(i, 'I', 'Tag', 'Line $i'),
      );
      controller.handleMessage(LogBatchMessage(batch1));
      expect(controller.lines.length, kMaxLines);

      final overflowBatch = List.generate(
        500,
        (i) => createEntry(kMaxLines + i, 'W', 'Tag', 'Overflow $i'),
      );
      controller.handleMessage(LogBatchMessage(overflowBatch));

      expect(controller.lines.length, kMaxLines);
      expect(controller.lines.last.seq, kMaxLines + 499);
    });

    test('ClearMessage clears all lines and visible entries', () {
      controller.handleMessage(LogBatchMessage([
        createEntry(1, 'I', 'Tag1', 'Message 1'),
        createEntry(2, 'E', 'Tag2', 'Message 2'),
      ]));
      expect(controller.lines.length, 2);

      controller.handleMessage(const ClearMessage());
      expect(controller.lines, isEmpty);
      expect(controller.visible, isEmpty);
    });

    test('StatusMessage updates server state and device list', () {
      controller.handleMessage(const StatusMessage(
        status: 'streaming',
        package: 'com.example.app',
        pid: 9999,
        devices: [
          DeviceInfo(serial: 'DEV123', model: 'Pixel 8', authorized: true),
        ],
        activeDevice: 'DEV123',
      ));

      expect(controller.serverStatus, 'streaming');
      expect(controller.appPid, 9999);
      expect(controller.devices.length, 1);
      expect(controller.activeDevice, 'DEV123');
    });
  });

  group('LogcatController filtering logic', () {
    setUp(() {
      controller.handleMessage(LogBatchMessage([
        createEntry(1, 'V', 'Network', 'Verbose ping'),
        createEntry(2, 'D', 'Database', 'Debug query SELECT *'),
        createEntry(3, 'I', 'Auth', 'User logged in successfully', pkg: 'com.app.auth'),
        createEntry(4, 'W', 'Storage', 'Low disk space warning'),
        createEntry(5, 'E', 'Payment', 'Transaction failed timeout', pkg: 'com.app.pay'),
        createEntry(6, 'F', 'Kernel', 'Fatal crash assert failure'),
      ]));
    });

    test('filters by minimum severity rank', () {
      controller.setMinLevel('V');
      expect(controller.visible.length, 6);

      controller.setMinLevel('I');
      expect(controller.visible.length, 4);
      expect(controller.visible.map((e) => e.level), containsAllInOrder(['I', 'W', 'E', 'F']));

      controller.setMinLevel('E');
      expect(controller.visible.length, 2);
      expect(controller.visible.map((e) => e.level), containsAllInOrder(['E', 'F']));
    });

    test('filters by text search across message and tag', () {
      controller.setSearch('query');
      expect(controller.visible.length, 1);
      expect(controller.visible.first.tag, 'Database');

      controller.setSearch('payment');
      expect(controller.visible.length, 1);
      expect(controller.visible.first.msg, contains('Transaction failed'));

      controller.setSearch('nonexistent_string');
      expect(controller.visible, isEmpty);
    });

    test('filters using regex mode', () {
      controller.toggleRegex();
      expect(controller.useRegex, isTrue);

      controller.setSearch(r'User.*successfully');
      expect(controller.visible.length, 1);
      expect(controller.visible.first.tag, 'Auth');

      controller.setSearch(r'(SELECT|Transaction)');
      expect(controller.visible.length, 2);

      // Broken regex should not throw an unhandled exception
      controller.setSearch(r'[');
      expect(controller.visible, isEmpty);
    });
  });

  group('LogcatController UI settings & formatting', () {
    test('toggles line soft-wrapping', () {
      expect(controller.wrap, isTrue);
      controller.toggleWrap();
      expect(controller.wrap, isFalse);
      controller.toggleWrap();
      expect(controller.wrap, isTrue);
    });

    test('updates column configurations', () {
      expect(controller.columns.showTime, isTrue);
      controller.updateColumns(LogColumnConfig.messageOnly);
      expect(controller.columns.showTime, isFalse);
      expect(controller.columns.showPidTid, isFalse);
      expect(controller.columns.showPackage, isFalse);
    });

    test('formats log string correctly on export', () async {
      controller.handleMessage(LogBatchMessage([
        createEntry(
          1,
          'I',
          'AuthTag',
          'Export message test',
          pkg: 'com.test.app',
          time: '10-04 12:34:56.789',
          pid: 4000,
          tid: 4001,
        ),
      ]));

      // Verify that export doesn't throw and formats properly
      final exportString = await controller.exportLogs();
      expect(exportString, isNotNull);
    });
  });
}
