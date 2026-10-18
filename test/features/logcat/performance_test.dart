@Tags(['perf'])
library;

import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/core/constants.dart';
import 'package:wcat/features/logcat/logcat_controller.dart';
import 'package:wcat/features/logcat/models/log_entry.dart';
import 'package:wcat/protocol/messages.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LogcatController controller;
  final random = Random(42);

  const tags = [
    'ActivityManager',
    'WindowManager',
    'SurfaceFlinger',
    'InputDispatcher',
    'AudioFlinger',
    'OkHttpClient',
    'AuthService',
    'DatabaseHelper',
    'CameraService',
    'NetworkSecurity',
  ];

  const sampleMessages = [
    'Displayed com.example.app/.MainActivity: +240ms',
    'SELECT * FROM users WHERE active = 1 AND permission_level > 3',
    'HTTP/1.1 200 OK (Content-Type: application/json; charset=utf-8, 142ms)',
    'VFS: file write complete on /sdcard/data/cache.bin',
    'Failed to acquire wake lock: timeout after 5000ms',
    'GC_CONCURRENT freed 2048K, 15% free 18MB/21MB, paused 2ms+3ms, total 18ms',
    'Choreographer: Skipped 4 frames! The application may be doing too much work on its main thread.',
    'Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0xdeadbeef',
    'Wrote 65536 bytes to socket descriptor fd=42',
    'User authentication succeeded for UID 10042',
  ];

  const levels = ['V', 'D', 'I', 'W', 'E', 'F'];

  List<LogEntry> generateBatch(int count, int startSeq) {
    return List.generate(count, (i) {
      final seq = startSeq + i;
      final level = levels[random.nextInt(levels.length)];
      final tag = tags[random.nextInt(tags.length)];
      final msg = sampleMessages[random.nextInt(sampleMessages.length)];
      return LogEntry(
        seq: seq,
        time: '10-18 11:00:${(i % 60).toString().padLeft(2, '0')}.123',
        pid: 1000 + (i % 20),
        tid: 2000 + (i % 50),
        level: level,
        tag: tag,
        msg: '$msg [trace_id: $seq]',
        pkg: (i % 3 == 0) ? 'com.example.app' : null,
      );
    });
  }

  setUp(() {
    controller = LogcatController();
  });

  tearDown(() {
    controller.dispose();
  });

  group('Performance & High-Throughput Benchmarks', () {
    test('BURST INTAKE: Ingests 50,000 log lines with bounded memory', () {
      final stopwatch = Stopwatch()..start();

      // Ingest 500 batches of 100 entries = 50,000 lines
      for (int b = 0; b < 500; b++) {
        final batch = generateBatch(100, b * 100);
        controller.handleMessage(LogBatchMessage(batch));
      }

      stopwatch.stop();

      // Assertions
      expect(
        controller.lines.length,
        kMaxLines,
        reason: 'Buffer must stay capped at exactly kMaxLines (8,000)',
      );
      expect(controller.lines.last.seq, 49999);

      // Verify high-throughput speed with generous threshold for CI runners
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(2000),
        reason:
            'Ingesting 50,000 lines took ${stopwatch.elapsedMilliseconds}ms; expected < 2000ms',
      );
    });

    test(
      'SUB-FRAME FILTERING: Text search over 8,000 lines completes responsively',
      () {
        // 1. Fill buffer to maximum capacity (8,000 entries)
        final fullBuffer = generateBatch(kMaxLines, 0);
        controller.handleMessage(HistoryMessage(fullBuffer));
        expect(controller.lines.length, kMaxLines);

        // 2. Measure search latency
        final stopwatch = Stopwatch()..start();
        controller.setSearch('authentication');
        stopwatch.stop();

        expect(controller.visible.isNotEmpty, isTrue);
        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(200),
          reason:
              'Filtering 8,000 lines took ${stopwatch.elapsedMilliseconds}ms; expected < 200ms',
        );
      },
    );

    test(
      'REGEX EVALUATION: Complex regex over 8,000 lines completes responsively',
      () {
        final fullBuffer = generateBatch(kMaxLines, 0);
        controller.handleMessage(HistoryMessage(fullBuffer));

        controller.toggleRegex();
        expect(controller.useRegex, isTrue);

        final stopwatch = Stopwatch()..start();
        controller.setSearch(
          r'(ActivityManager|Choreographer).*Skipped [0-9]+ frames',
        );
        stopwatch.stop();

        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(300),
          reason:
              'Regex search over 8,000 lines took ${stopwatch.elapsedMilliseconds}ms; expected < 300ms',
        );
      },
    );

    test(
      'SEVERITY FILTER: Level ranking over 8,000 lines completes responsively',
      () {
        final fullBuffer = generateBatch(kMaxLines, 0);
        controller.handleMessage(HistoryMessage(fullBuffer));

        final stopwatch = Stopwatch()..start();
        controller.setMinLevel('E');
        stopwatch.stop();

        // Only E and F should remain
        expect(
          controller.visible.every((e) => e.level == 'E' || e.level == 'F'),
          isTrue,
        );
        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(150),
          reason:
              'Level filtering took ${stopwatch.elapsedMilliseconds}ms; expected < 150ms',
        );
      },
    );

    test(
      'STREAM DURATION (T.5b): 100,000 lines continuous stream maintains buffer cap',
      () {
        final stopwatch = Stopwatch()..start();

        // Simulate 1,000 incoming batches
        for (int i = 0; i < 1000; i++) {
          final batch = generateBatch(100, i * 100);
          controller.handleMessage(LogBatchMessage(batch));
          // Verify buffer never exceeds configured cap
          expect(controller.lines.length, lessThanOrEqualTo(kMaxLines * 2));
        }

        stopwatch.stop();

        // Confirm buffer remains capped at max capacity
        expect(controller.lines.length, kMaxLines);
        expect(controller.lines.last.seq, 99999);
      },
    );

    test(
      'INCREMENTAL FILTER (T.5c): Appending batch to active filter completes fast',
      () {
        // 1. Populate initial 8,000 lines with an active filter
        final fullBuffer = generateBatch(kMaxLines, 0);
        controller.handleMessage(HistoryMessage(fullBuffer));
        controller.setSearch('authentication');
        final initialVisibleCount = controller.visible.length;

        // 2. Measure latency of appending a new batch
        final stopwatch = Stopwatch()..start();
        final newBatch = generateBatch(100, 8000);
        controller.handleMessage(LogBatchMessage(newBatch));
        stopwatch.stop();

        expect(
          controller.visible.length,
          greaterThanOrEqualTo(initialVisibleCount),
        );
        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(100),
          reason:
              'Appending batch to active filter took ${stopwatch.elapsedMilliseconds}ms; expected < 100ms',
        );
      },
    );

    test(
      'BULK EXPORT: Formatting 8,000 full log lines into string completes responsively',
      () async {
        final fullBuffer = generateBatch(kMaxLines, 0);
        controller.handleMessage(HistoryMessage(fullBuffer));

        final stopwatch = Stopwatch()..start();
        final exportString = await controller.exportLogs();
        stopwatch.stop();

        expect(exportString, isNotNull);
        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(350),
          reason:
              'Bulk export of 8,000 lines took ${stopwatch.elapsedMilliseconds}ms; expected < 350ms',
        );
      },
    );
  });
}
