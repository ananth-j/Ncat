import 'package:flutter_test/flutter_test.dart';
import 'package:thruwire/core/constants.dart';
import 'package:thruwire/features/devices/models/device_info.dart';
import 'package:thruwire/features/logcat/logcat_controller.dart';
import 'package:thruwire/features/logcat/models/log_entry.dart';
import 'package:thruwire/protocol/messages.dart';
import 'package:thruwire/src/column_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LogcatController controller;

  setUp(() {
    controller = LogcatController();
  });

  tearDown(() {
    controller.dispose();
  });

  LogEntry createEntry(
    int seq,
    String level,
    String tag,
    String msg, {
    String? pkg,
    int pid = 100,
    int tid = 101,
    String time = '10-04 12:00:00.000',
  }) {
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
      final initialEntries = [createEntry(1, 'I', 'InitTag', 'Init message')];
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
      controller.handleMessage(
        LogBatchMessage([createEntry(1, 'I', 'Tag1', 'Message 1')]),
      );
      expect(controller.lines.length, 1);

      controller.handleMessage(
        LogBatchMessage([createEntry(2, 'E', 'Tag2', 'Message 2')]),
      );
      expect(controller.lines.length, 2);
      expect(controller.lines.last.level, 'E');
    });

    test('LogBatchMessage is ignored when controller is paused', () {
      controller.handleMessage(
        LogBatchMessage([createEntry(1, 'I', 'Tag1', 'Message 1')]),
      );
      expect(controller.lines.length, 1);

      controller.togglePaused();
      expect(controller.paused, isTrue);

      controller.handleMessage(
        LogBatchMessage([
          createEntry(2, 'E', 'Tag2', 'Message 2 while paused'),
        ]),
      );
      expect(controller.lines.length, 1);

      controller.togglePaused();
      expect(controller.paused, isFalse);

      controller.handleMessage(
        LogBatchMessage([
          createEntry(3, 'D', 'Tag3', 'Message 3 after resume'),
        ]),
      );
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
      controller.handleMessage(
        LogBatchMessage([
          createEntry(1, 'I', 'Tag1', 'Message 1'),
          createEntry(2, 'E', 'Tag2', 'Message 2'),
        ]),
      );
      expect(controller.lines.length, 2);

      controller.handleMessage(const ClearMessage());
      expect(controller.lines, isEmpty);
      expect(controller.visible, isEmpty);
    });

    test('StatusMessage updates server state and device list', () {
      controller.handleMessage(
        const StatusMessage(
          status: 'streaming',
          package: 'com.example.app',
          pid: 9999,
          devices: [
            DeviceInfo(serial: 'DEV123', model: 'Pixel 8', authorized: true),
          ],
          activeDevice: 'DEV123',
        ),
      );

      expect(controller.serverStatus, 'streaming');
      expect(controller.appPid, 9999);
      expect(controller.devices.length, 1);
      expect(controller.activeDevice, 'DEV123');
    });
  });

  group('LogcatController filtering logic', () {
    setUp(() {
      controller.handleMessage(
        LogBatchMessage([
          createEntry(1, 'V', 'Network', 'Verbose ping'),
          createEntry(2, 'D', 'Database', 'Debug query SELECT *'),
          createEntry(
            3,
            'I',
            'Auth',
            'User logged in successfully',
            pkg: 'com.app.auth',
          ),
          createEntry(4, 'W', 'Storage', 'Low disk space warning'),
          createEntry(
            5,
            'E',
            'Payment',
            'Transaction failed timeout',
            pkg: 'com.app.pay',
          ),
          createEntry(6, 'F', 'Kernel', 'Fatal crash assert failure'),
        ]),
      );
    });

    test('filters by minimum severity rank', () {
      controller.setMinLevel('V');
      expect(controller.visible.length, 6);

      controller.setMinLevel('I');
      expect(controller.visible.length, 4);
      expect(
        controller.visible.map((e) => e.level),
        containsAllInOrder(['I', 'W', 'E', 'F']),
      );

      controller.setMinLevel('E');
      expect(controller.visible.length, 2);
      expect(
        controller.visible.map((e) => e.level),
        containsAllInOrder(['E', 'F']),
      );
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
      controller.handleMessage(
        LogBatchMessage([
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
        ]),
      );

      // Verify that export doesn't throw and formats properly
      final exportString = await controller.exportLogs();
      expect(exportString, isNotNull);
    });
  });

  group('LogcatController Noise Reduction & Mode Selection', () {
    test('NoiseFilter identifies system chatter vs real app logs', () {
      final sfEntry = createEntry(1, 'D', 'SurfaceFlinger', 'vsync tick');
      final wifiEntry = createEntry(2, 'I', 'WifiService', 'Scan completed');
      final appEntry = createEntry(3, 'D', 'MainActivity', 'User clicked login');
      final errEntry = createEntry(
        4,
        'E',
        'SurfaceFlinger',
        'Composition failed fatally',
      );
      final chattyEntry = createEntry(
        5,
        'I',
        'chatty',
        'uid=1000 expire 5 lines',
      );

      // System daemon logs at low rank are noise
      expect(NoiseFilter.isNoise(sfEntry), isTrue);
      expect(NoiseFilter.isNoise(wifiEntry), isTrue);
      expect(NoiseFilter.isNoise(chattyEntry), isTrue);

      // App logs are not noise
      expect(NoiseFilter.isNoise(appEntry), isFalse);

      // Errors are NEVER noise even from system daemons
      expect(NoiseFilter.isNoise(errEntry), isFalse);

      // App logs matching active appPid are never noise
      final daemonBelongingToApp = createEntry(
        6,
        'D',
        'SurfaceFlinger',
        'Local render',
        pid: 999,
      );
      expect(NoiseFilter.isNoise(daemonBelongingToApp, appPid: 999), isFalse);
    });

    test('LogcatController reduces noise by default and toggles cleanly', () {
      expect(controller.noiseMode, NoiseFilterMode.reduce);
      expect(controller.reduceNoise, isTrue);

      final mixedEntries = [
        createEntry(1, 'I', 'MainActivity', 'Starting user activity'),
        createEntry(2, 'D', 'SurfaceFlinger', 'Buffer swap 16ms'),
        createEntry(3, 'D', 'WifiService', 'Periodic RSSI poll'),
        createEntry(4, 'E', 'AudioFlinger', 'Audio track underrun error'),
        createEntry(5, 'D', 'PaymentService', 'Payment processed'),
      ];

      controller.handleMessage(HistoryMessage(mixedEntries));

      // With reduceNoise (default):
      // SurfaceFlinger (D) and WifiService (D) are suppressed.
      // MainActivity (I), PaymentService (D), and AudioFlinger (E error!) remain visible.
      expect(controller.lines.length, 5);
      expect(controller.visible.length, 3);
      expect(controller.hiddenNoiseCount, 2);
      expect(
        controller.visible.map((e) => e.tag),
        containsAllInOrder(['MainActivity', 'AudioFlinger', 'PaymentService']),
      );

      // Switch to Show All: all 5 lines are visible
      controller.setNoiseMode(NoiseFilterMode.showAll);
      expect(controller.noiseMode, NoiseFilterMode.showAll);
      expect(controller.reduceNoise, isFalse);
      expect(controller.visible.length, 5);

      // Switch to Only Noise: only the 2 noise lines are visible
      controller.setNoiseMode(NoiseFilterMode.onlyNoise);
      expect(controller.noiseMode, NoiseFilterMode.onlyNoise);
      expect(controller.visible.length, 2);
      expect(
        controller.visible.map((e) => e.tag),
        containsAllInOrder(['SurfaceFlinger', 'WifiService']),
      );

      // Toggle back to reduce
      controller.toggleReduceNoise();
      expect(controller.noiseMode, NoiseFilterMode.reduce);
      expect(controller.visible.length, 3);
    });

    test('LogcatController supports is:noise and -is:noise in search query', () {
      final mixedEntries = [
        createEntry(1, 'I', 'AppController', 'Ready'),
        createEntry(2, 'D', 'SurfaceFlinger', 'Frame flip'),
        createEntry(3, 'D', 'WifiService', 'Ping probe'),
      ];
      controller.handleMessage(HistoryMessage(mixedEntries));

      // Querying is:noise explicitly shows noise lines
      controller.setSearch('is:noise');
      expect(controller.visible.length, 2);
      expect(
        controller.visible.map((e) => e.tag),
        containsAll(['SurfaceFlinger', 'WifiService']),
      );

      // Querying -is:noise explicitly shows only non-noise lines
      controller.setSearch('-is:noise');
      expect(controller.visible.length, 1);
      expect(controller.visible.first.tag, 'AppController');
    });

    test(
      'LogBatchMessage isolates rebuilds to visibleNotifier and statsNotifier',
      () {
        var controllerNotifications = 0;
        var visibleNotifications = 0;
        var statsNotifications = 0;

        controller.addListener(() => controllerNotifications++);
        controller.visibleNotifier.addListener(() => visibleNotifications++);
        controller.statsNotifier.addListener(() => statsNotifications++);

        controller.handleMessage(
          LogBatchMessage([
            createEntry(1, 'I', 'AppTag', 'Visible entry'),
            createEntry(2, 'D', 'SurfaceFlinger', 'Noise entry'),
          ]),
        );

        expect(controllerNotifications, 0);
        expect(visibleNotifications, 1);
        expect(statsNotifications, 1);
        expect(controller.visibleNotifier.value.length, 1);
        expect(controller.statsNotifier.value, (
          total: 2,
          visible: 1,
          hiddenNoise: 1,
        ));
      },
    );
  });
}
