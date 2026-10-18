import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/features/devices/models/device_info.dart';
import 'package:wcat/features/logcat/models/log_entry.dart';
import 'package:wcat/features/logcat/widgets/left_vertical_toolbar.dart';
import 'package:wcat/features/logcat/widgets/log_row.dart';
import 'package:wcat/features/logcat/widgets/status_bar.dart';
import 'package:wcat/features/logcat/widgets/top_filter_bar.dart';
import 'package:wcat/src/column_config.dart';
import 'package:wcat/src/palette.dart';

Widget wrapWithTheme(Widget child) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.dark, kDarkModernPalette),
    home: Scaffold(body: child),
  );
}

void setDesktopSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  group('TopFilterBar Widget Tests', () {
    testWidgets('renders all controls and triggers callbacks', (tester) async {
      setDesktopSize(tester);

      String searchVal = '';
      bool regexToggled = false;

      final searchCtrl = TextEditingController();
      final pkgCtrl = TextEditingController();

      await tester.pumpWidget(
        wrapWithTheme(
          TopFilterBar(
            searchCtrl: searchCtrl,
            pkgCtrl: pkgCtrl,
            minLevel: 'V',
            useRegex: false,
            appPid: 1234,
            devices: const [DeviceInfo(serial: 'DEV1', model: 'Pixel 8')],
            pickedDevice: 'DEV1',
            onSearch: (v) => searchVal = v,
            onLevel: (_) {},
            onPackage: () {},
            onRegex: () => regexToggled = true,
            onDevice: (_) {},
          ),
        ),
      );

      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('.*'), findsOneWidget);
      expect(find.text('1234'), findsOneWidget);

      // Tap regex button
      await tester.tap(find.text('.*'));
      expect(regexToggled, isTrue);

      // Enter search text
      await tester.enterText(find.byType(TextField).last, 'my query');
      expect(searchVal, 'my query');

      searchCtrl.dispose();
      pkgCtrl.dispose();
    });
  });

  group('LeftVerticalToolbar Widget Tests', () {
    testWidgets('triggers action callbacks', (tester) async {
      setDesktopSize(tester);

      bool paused = false;
      bool cleared = false;
      bool wrapped = true;

      await tester.pumpWidget(
        wrapWithTheme(
          LeftVerticalToolbar(
            paused: false,
            wrap: true,
            atBottom: true,
            themeChoice: AppThemeChoice.darkModern,
            onPause: () => paused = true,
            onWrap: () => wrapped = false,
            onScrollToEnd: () {},
            onScrollToTop: () {},
            onClear: () => cleared = true,
            onRestart: () {},
            onExport: () {},
            onPresets: () {},
            onConfigureColumns: () {},
            onThemeChoice: (_) {},
          ),
        ),
      );

      // Verify clear button tap
      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      expect(cleared, isTrue);

      // Verify pause button tap
      await tester.tap(find.byIcon(Icons.pause));
      expect(paused, isTrue);

      // Verify wrap button tap
      await tester.tap(find.byIcon(Icons.wrap_text));
      expect(wrapped, isFalse);
    });
  });

  group('LogcatStatusBar Widget Tests', () {
    testWidgets('displays server status, active device, and metrics', (
      tester,
    ) async {
      setDesktopSize(tester);

      await tester.pumpWidget(
        wrapWithTheme(
          const LogcatStatusBar(
            connection: 'live',
            serverStatus: 'streaming logcat',
            activeDevice: 'DEV123',
            devices: [DeviceInfo(serial: 'DEV123', model: 'Galaxy S24')],
            appPid: 5432,
            paused: true,
            autoScroll: false,
            visibleCount: 42,
            totalCount: 100,
          ),
        ),
      );

      expect(find.text('streaming logcat'), findsOneWidget);
      expect(find.text('Galaxy S24 (DEV123)'), findsOneWidget);
      expect(find.text('PID: 5432'), findsOneWidget);
      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.text('SCROLL PAUSED'), findsOneWidget);
      expect(find.text('42 of 100 lines'), findsOneWidget);
    });
  });

  group('LogRow Widget Tests', () {
    testWidgets(
      'renders all columns and displays context menu on secondary tap',
      (tester) async {
        setDesktopSize(tester);

        const entry = LogEntry(
          seq: 1,
          time: '10-18 10:20:30.123',
          pid: 1234,
          tid: 1235,
          level: 'E',
          tag: 'TestTag',
          msg: 'Something went wrong',
          pkg: 'com.example.app',
        );

        bool copyCalled = false;
        String filterTag = '';

        await tester.pumpWidget(
          wrapWithTheme(
            LogRow(
              entry: entry,
              columns: LogColumnConfig.standard,
              wrap: true,
              onCopy: () => copyCalled = true,
              onFilterTag: () => filterTag = 'TestTag',
              onFilterPackage: (_) {},
            ),
          ),
        );

        expect(find.text('10-18 10:20:30.123'), findsOneWidget);
        expect(find.text('1234-1235'), findsOneWidget);
        expect(find.text('com.example.app'), findsOneWidget);
        expect(find.text('E'), findsOneWidget);
        expect(find.text('TestTag'), findsOneWidget);
        expect(find.text('Something went wrong'), findsOneWidget);

        // Right-click / Secondary tap
        await tester.tapAt(tester.getCenter(find.byType(LogRow)), buttons: 2);
        await tester.pumpAndSettle();

        expect(find.text('Copy full line'), findsOneWidget);
        expect(find.text('Filter by tag: "TestTag"'), findsOneWidget);

        // Tap Copy full line
        await tester.tap(find.text('Copy full line'));
        await tester.pumpAndSettle();
        expect(copyCalled, isTrue);

        // Open context menu again and tap Filter by tag
        await tester.tapAt(tester.getCenter(find.byType(LogRow)), buttons: 2);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Filter by tag: "TestTag"'));
        await tester.pumpAndSettle();
        expect(filterTag, 'TestTag');
      },
    );
  });
}
