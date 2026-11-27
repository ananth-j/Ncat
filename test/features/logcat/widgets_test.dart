import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thruwire/features/devices/device_controller.dart';
import 'package:thruwire/features/devices/models/device_info.dart';
import 'package:thruwire/features/logcat/logcat_controller.dart'
    show LogSplitAxis;
import 'package:thruwire/features/logcat/models/log_entry.dart';
import 'package:thruwire/features/logcat/models/log_tab_state.dart';
import 'package:thruwire/features/logcat/models/noise_filter.dart';
import 'package:thruwire/features/logcat/widgets/left_vertical_toolbar.dart';
import 'package:thruwire/features/logcat/widgets/log_row.dart';
import 'package:thruwire/features/logcat/widgets/log_tab_bar.dart';
import 'package:thruwire/features/logcat/widgets/status_bar.dart';
import 'package:thruwire/features/logcat/widgets/top_filter_bar.dart';
import 'package:thruwire/src/column_config.dart';
import 'package:thruwire/src/palette.dart';

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

    testWidgets('renders noise reduction control and handles mode change', (
      tester,
    ) async {
      setDesktopSize(tester);

      NoiseFilterMode selectedMode = NoiseFilterMode.reduce;
      final searchCtrl = TextEditingController();
      final pkgCtrl = TextEditingController();

      await tester.pumpWidget(
        wrapWithTheme(
          TopFilterBar(
            searchCtrl: searchCtrl,
            pkgCtrl: pkgCtrl,
            minLevel: 'V',
            useRegex: false,
            appPid: null,
            devices: const [],
            pickedDevice: null,
            noiseMode: NoiseFilterMode.reduce,
            onSearch: (_) {},
            onLevel: (_) {},
            onPackage: () {},
            onRegex: () {},
            onDevice: (_) {},
            onNoiseMode: (mode) => selectedMode = mode,
          ),
        ),
      );

      expect(find.text('Noise: Reduced'), findsOneWidget);

      // Open noise popup menu
      await tester.tap(find.text('Noise: Reduced'));
      await tester.pumpAndSettle();

      expect(find.text('Show All (Include Noise)'), findsOneWidget);
      expect(find.text('Only Noise'), findsOneWidget);

      // Select Show All
      await tester.tap(find.text('Show All (Include Noise)'));
      await tester.pumpAndSettle();

      expect(selectedMode, NoiseFilterMode.showAll);

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

    testWidgets('displays noise hidden count when noise reduction is active', (
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
            appPid: null,
            paused: false,
            autoScroll: true,
            visibleCount: 42,
            totalCount: 100,
            hiddenNoiseCount: 58,
            reduceNoise: true,
          ),
        ),
      );

      expect(find.text('42 of 100 lines (58 noise hidden)'), findsOneWidget);
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
              onCopy: (_) => copyCalled = true,
              onFilterTag: (_) => filterTag = 'TestTag',
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

  group('LogTabBar Widget Tests', () {
    testWidgets(
      'renders tabs for single device, supports add/select/close and context menu',
      (tester) async {
        setDesktopSize(tester);

        String? selectedTab;
        String? closedTab;
        String? duplicatedTab;
        LogSplitAxis? toggledSplit;
        (String, LogSplitAxis)? splitWith;
        bool added = false;

        final tabs = [
          LogTabState(
            id: 'tab_1',
            title: 'Logcat 1',
            packageFilter: 'com.app.main',
          ),
          LogTabState(
            id: 'tab_2',
            title: 'Errors',
            isCustomTitle: true,
            minLevel: 'E',
            paused: true,
          ),
        ];

        await tester.pumpWidget(
          wrapWithTheme(
            LogTabBar(
              tabs: tabs,
              activeTabId: 'tab_1',
              devices: const [
                DeviceInfo(serial: 'DEV1', model: 'Pixel 8', authorized: true),
              ],
              activeDeviceSerial: 'DEV1',
              viewMode: DeviceViewMode.singleOrTabs,
              onSelectTab: (id) => selectedTab = id,
              onAddTab: () => added = true,
              onCloseTab: (id) => closedTab = id,
              onDuplicateTab: (id) => duplicatedTab = id,
              onRenameTab: (_, __) {},
              onCloseOtherTabs: (_) {},
              onCloseTabsToRight: (_) {},
              onSplitWithTab: (id, axis) => splitWith = (id, axis),
              onToggleSplit: (axis) => toggledSplit = axis,
              onToggleViewMode: () {},
            ),
          ),
        );

        expect(find.text('com.app.main'), findsOneWidget);
        expect(find.text('Errors'), findsOneWidget);
        expect(find.text('E+'), findsOneWidget);

        // Tap second tab to select
        await tester.tap(find.text('Errors'));
        await tester.pump();
        expect(selectedTab, 'tab_2');

        // Tap '+' button to add a tab
        await tester.tap(find.byIcon(Icons.add));
        await tester.pump();
        expect(added, isTrue);

        // Tap close icon on active tab
        await tester.tap(find.byIcon(Icons.close).first);
        await tester.pump();
        expect(closedTab, 'tab_1');

        // Secondary tap opens context menu with Duplicate Tab
        await tester.tapAt(
          tester.getCenter(find.text('com.app.main')),
          buttons: 2,
        );
        await tester.pumpAndSettle();
        expect(find.text('Duplicate Tab'), findsOneWidget);
        expect(find.text('Split Right (Side-by-Side)'), findsOneWidget);
        await tester.tap(find.text('Duplicate Tab'));
        await tester.pumpAndSettle();
        expect(duplicatedTab, 'tab_1');

        // Split Right button in tab bar triggers onToggleSplit
        await tester.tap(find.byIcon(Icons.vertical_split_outlined));
        await tester.pump();
        expect(toggledSplit, LogSplitAxis.horizontal);

        // Context menu Split Right triggers onSplitWithTab
        await tester.tapAt(
          tester.getCenter(find.text('Errors')),
          buttons: 2,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Split Right (Side-by-Side)'));
        await tester.pumpAndSettle();
        expect(splitWith, ('tab_2', LogSplitAxis.horizontal));
      },
    );
  });
}
