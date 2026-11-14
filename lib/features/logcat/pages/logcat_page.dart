import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../src/palette.dart';
import '../../devices/widgets/device_tab_bar.dart';
import '../../mirroring/capture_service.dart';
import '../../mirroring/mirror_controller.dart';
import '../../mirroring/widgets/multi_screen_grid.dart';
import '../../mirroring/widgets/screen_mirror_view.dart';
import '../../mirroring/widgets/screenshot_dialog.dart';
import '../logcat_controller.dart';
import '../widgets/column_config_dialog.dart';
import '../widgets/left_vertical_toolbar.dart';
import '../widgets/log_table_view.dart';
import '../widgets/presets_dialog.dart';
import '../widgets/status_bar.dart';
import '../widgets/top_filter_bar.dart';

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

class _LogcatPageState extends State<LogcatPage> with WidgetsBindingObserver {
  late final LogcatController _controller;
  late final CaptureService _captureService;
  late final MirrorController _mirrorController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = LogcatController()..init();
    _captureService = CaptureService();
    _mirrorController = MirrorController();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      _mirrorController.onPause();
    } else if (state == AppLifecycleState.resumed) {
      _mirrorController.onResume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mirrorController.dispose();
    _captureService.dispose();
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
          side: BorderSide(
            color: isError ? Colors.transparent : palette.border,
          ),
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

  Future<void> _handleScreenshot() async {
    final serial = _controller.activeDevice;
    _notify('Capturing screenshot...');
    try {
      final bytes = await _captureService.takeScreenshot(serial: serial);
      if (bytes != null && mounted) {
        await ScreenshotDialog.show(
          context: context,
          bytes: bytes,
          serial: serial,
          onSave: (b) async {
            final path = await _captureService.saveScreenshot(
              b,
              serial: serial,
            );
            _notify('Screenshot saved: $path');
          },
        );
      } else {
        _notify('Screenshot failed (no image data returned)', isError: true);
      }
    } catch (e) {
      _notify('Screenshot failed: $e', isError: true);
    }
  }

  Future<void> _handleToggleRecord() async {
    final serial = _controller.activeDevice;
    if (_captureService.isRecording.value) {
      _notify('Finalizing MP4 recording (sending SIGINT on device)...');
      try {
        final bytes = await _captureService.stopRecording(serial: serial);
        if (bytes != null) {
          final path = await _captureService.saveRecording(
            bytes,
            serial: serial,
          );
          _notify('Screen recording saved: $path');
        } else {
          _notify('Failed to finalize or pull recording', isError: true);
        }
      } catch (e) {
        _notify('Stop recording failed: $e', isError: true);
      }
    } else {
      _notify('Starting screen recording on device...');
      final started = await _captureService.startRecording(serial: serial);
      if (started) {
        _notify('● Recording in progress (hardware-encoded)');
      } else {
        _notify('Failed to start recording on device', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(
              LogicalKeyboardKey.keyS,
              control: true,
              shift: true,
            ):
            _handleScreenshot,
        const SingleActivator(
              LogicalKeyboardKey.keyR,
              control: true,
              shift: true,
            ):
            _handleToggleRecord,
        const SingleActivator(
          LogicalKeyboardKey.keyM,
          control: true,
          shift: true,
        ): () => _mirrorController.toggleOpen(serial: _controller.activeDevice),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true):
            _controller.clearLogs,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: palette.bg,
          body: Column(
            children: [
              // Top horizontal filter bar - rebuilds on filter/device changes
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  return TopFilterBar(
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
                  );
                },
              ),

              // Per-device tabs bar (Phase 5.1) - rebuilds on device tab changes
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  return DeviceTabBar(
                    devices: _controller.devices,
                    activeSerial: _controller.activeDevice,
                    viewMode: _controller.viewMode,
                    onSelectDevice: _controller.selectDeviceTab,
                    onToggleViewMode: _controller.toggleViewMode,
                  );
                },
              ),

              // Main viewport area: either MultiScreenGrid or Logcat Console
              Expanded(
                child: ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) {
                    if (_controller.viewMode == DeviceViewMode.grid) {
                      return MultiScreenGrid(
                        devices: _controller.devices,
                        captureService: _captureService,
                        activeSerial: _controller.activeDevice,
                        onSelectDevice: (serial) {
                          _controller.selectDeviceTab(serial);
                          _controller.setViewMode(DeviceViewMode.singleOrTabs);
                        },
                        onCloseGrid:
                            () => _controller.setViewMode(
                              DeviceViewMode.singleOrTabs,
                            ),
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Left vertical action toolbar with localized capture & mirror reactivity
                        ListenableBuilder(
                          listenable: Listenable.merge([
                            _controller,
                            _captureService.isRecording,
                            _captureService.recordingDuration,
                            _captureService.isTakingScreenshot,
                            _mirrorController.isOpen,
                          ]),
                          builder: (context, _) {
                            return LeftVerticalToolbar(
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
                              onScreenshot: _handleScreenshot,
                              onToggleRecord: _handleToggleRecord,
                              onToggleMirror:
                                  () => _mirrorController.toggleOpen(
                                    serial: _controller.activeDevice,
                                  ),
                              isMirrorOpen: _mirrorController.isOpen.value,
                              isRecording: _captureService.isRecording.value,
                              recordingDuration:
                                  _captureService.recordingDuration.value,
                              isTakingScreenshot:
                                  _captureService.isTakingScreenshot.value,
                              onPresets:
                                  () => showPresetsDialog(
                                    context: context,
                                    presets: _controller.presets,
                                    onApplyPreset: _controller.applyPreset,
                                    onSavePreset: _controller.savePreset,
                                    onDeletePreset: _controller.deletePreset,
                                  ),
                              onConfigureColumns:
                                  () => showColumnConfigDialog(
                                    context: context,
                                    columns: _controller.columns,
                                    onUpdateColumns: _controller.updateColumns,
                                  ),
                              onThemeChoice: widget.onThemeChoice,
                            );
                          },
                        ),

                        // Log entries table view - rebuilds only on controller state changes
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

                        // Screen Mirror split view - rebuilds only on mirror open toggle
                        ValueListenableBuilder<bool>(
                          valueListenable: _mirrorController.isOpen,
                          builder: (context, isOpen, _) {
                            if (!isOpen) return const SizedBox.shrink();
                            return SizedBox(
                              width: 340,
                              child: ScreenMirrorView(
                                controller: _mirrorController,
                                onClose: () => _mirrorController.setOpen(false),
                              ),
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),

              // Bottom status bar - rebuilds on log/connection counts
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  return LogcatStatusBar(
                    connection: _controller.connection,
                    serverStatus: _controller.serverStatus,
                    activeDevice: _controller.activeDevice,
                    devices: _controller.devices,
                    appPid: _controller.appPid,
                    paused: _controller.paused,
                    autoScroll: _controller.autoScroll,
                    visibleCount: _controller.visible.length,
                    totalCount: _controller.lines.length,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
