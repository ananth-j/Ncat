import 'package:flutter/material.dart';

import 'features/logcat/logcat_controller.dart';
import 'features/logcat/widgets/column_config_dialog.dart';
import 'features/logcat/widgets/left_vertical_toolbar.dart';
import 'features/logcat/widgets/log_table_view.dart';
import 'features/logcat/widgets/presets_dialog.dart';
import 'features/logcat/widgets/status_bar.dart';
import 'features/logcat/widgets/top_filter_bar.dart';
import 'src/palette.dart';
import 'src/theme_pref.dart';

// Re-export core types for backward compatibility and test convenience
export 'core/constants.dart';
export 'features/devices/models/device_info.dart';
export 'features/logcat/models/log_entry.dart';
export 'src/column_config.dart';
export 'src/palette.dart';

void main() => runApp(const LogcatApp());

/// Root application widget configuring themes and initial routes.
class LogcatApp extends StatefulWidget {
  const LogcatApp({super.key});

  @override
  State<LogcatApp> createState() => _LogcatAppState();
}

class _LogcatAppState extends State<LogcatApp> {
  AppThemeChoice _themeChoice = AppThemeChoice.system;
  bool _userChangedTheme = false;

  @override
  void initState() {
    super.initState();
    loadThemeChoice().then((choice) {
      if (mounted && !_userChangedTheme) setState(() => _themeChoice = choice);
    });
  }

  void _setThemeChoice(AppThemeChoice choice) {
    _userChangedTheme = true;
    setState(() => _themeChoice = choice);
    saveThemeChoice(choice);
  }

  @override
  Widget build(BuildContext context) {
    final darkPalette = _themeChoice == AppThemeChoice.vsDark
        ? kVsDarkPalette
        : kDarkModernPalette;

    return MaterialApp(
      title: 'wcat',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light, kLightPalette),
      darkTheme: buildAppTheme(Brightness.dark, darkPalette),
      themeMode: switch (_themeChoice) {
        AppThemeChoice.system => ThemeMode.system,
        AppThemeChoice.light => ThemeMode.light,
        AppThemeChoice.darkModern || AppThemeChoice.vsDark => ThemeMode.dark,
      },
      home: LogcatPage(
        themeChoice: _themeChoice,
        onThemeChoice: _setThemeChoice,
      ),
    );
  }
}

/// Main desktop/web viewport displaying the toolbar, logcat grid, and status indicators.
class LogcatPage extends StatefulWidget {
  const LogcatPage({
    super.key,
    required this.themeChoice,
    required this.onThemeChoice,
  });

  final AppThemeChoice themeChoice;
  final ValueChanged<AppThemeChoice> onThemeChoice;

  @override
  State<LogcatPage> createState() => _LogcatPageState();
}

class _LogcatPageState extends State<LogcatPage> {
  late final LogcatController _controller;

  @override
  void initState() {
    super.initState();
    _controller = LogcatController()..init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _notify(String message, {bool isError = false}) {
    if (!mounted) return;
    final palette = context.palette;
    final sm = ScaffoldMessenger.maybeOf(context);
    if (sm == null) return;
    sm.hideCurrentSnackBar();
    sm.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            fontSize: 12,
            color: isError ? Colors.white : palette.text,
          ),
        ),
        backgroundColor: isError ? const Color(0xFFC5333D) : palette.panel,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side:
              BorderSide(color: isError ? Colors.transparent : palette.border),
        ),
      ),
    );
  }

  Future<void> _handleExport() async {
    try {
      final result = await _controller.exportLogs();
      _notify(result);
    } catch (e) {
      _notify('export failed: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: palette.bg,
          body: Column(
            children: [
              // Top horizontal filter bar
              TopFilterBar(
                searchCtrl: _controller.searchController,
                pkgCtrl: _controller.pkgController,
                minLevel: _controller.minLevel,
                useRegex: _controller.useRegex,
                appPid: _controller.appPid,
                devices: _controller.devices,
                pickedDevice: _controller.pickedDevice,
                onSearch: _controller.setSearch,
                onLevel: _controller.setMinLevel,
                onPackage: _controller.applyPackage,
                onRegex: _controller.toggleRegex,
                onDevice: _controller.applyDevice,
              ),

              // Main log console area with left vertical action strip
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Left vertical action toolbar
                    LeftVerticalToolbar(
                      paused: _controller.paused,
                      wrap: _controller.wrap,
                      atBottom: _controller.autoScroll,
                      themeChoice: widget.themeChoice,
                      onPause: _controller.togglePaused,
                      onWrap: _controller.toggleWrap,
                      onScrollToEnd: _controller.scrollToEnd,
                      onScrollToTop: _controller.scrollToTop,
                      onClear: _controller.clearLogs,
                      onRestart: _controller.restartAdb,
                      onExport: _handleExport,
                      onPresets: () => showPresetsDialog(
                        context: context,
                        presets: _controller.presets,
                        onApplyPreset: _controller.applyPreset,
                        onSavePreset: _controller.savePreset,
                        onDeletePreset: _controller.deletePreset,
                      ),
                      onConfigureColumns: () => showColumnConfigDialog(
                        context: context,
                        columns: _controller.columns,
                        onUpdateColumns: _controller.updateColumns,
                      ),
                      onThemeChoice: widget.onThemeChoice,
                    ),

                    // Log entries table view
                    Expanded(
                      child: LogTableView(
                        entries: _controller.visible,
                        totalLinesCount: _controller.lines.length,
                        columns: _controller.columns,
                        wrap: _controller.wrap,
                        autoScroll: _controller.autoScroll,
                        scrollController: _controller.scrollController,
                        appPid: _controller.appPid,
                        packageFilter: _controller.pkgController.text.trim(),
                        onCopy: (entry) {
                          _controller.copyLogEntry(entry);
                          _notify('Log line copied to clipboard');
                        },
                        onFilterTag: _controller.setFilterTag,
                        onFilterPackage: _controller.setFilterPackage,
                        onScrollToEnd: _controller.scrollToEnd,
                        onUpdateColumns: _controller.updateColumns,
                      ),
                    ),
                  ],
                ),
              ),

              // Bottom status bar
              LogcatStatusBar(
                connection: _controller.connection,
                serverStatus: _controller.serverStatus,
                activeDevice: _controller.activeDevice,
                devices: _controller.devices,
                appPid: _controller.appPid,
                paused: _controller.paused,
                autoScroll: _controller.autoScroll,
                visibleCount: _controller.visible.length,
                totalCount: _controller.lines.length,
              ),
            ],
          ),
        );
      },
    );
  }
}
