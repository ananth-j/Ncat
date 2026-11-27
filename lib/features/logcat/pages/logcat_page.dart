import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../src/palette.dart';
import '../../mirroring/capture_service.dart';
import '../../mirroring/mirror_controller.dart';
import '../../mirroring/widgets/multi_screen_grid.dart';
import '../../mirroring/widgets/screen_mirror_view.dart';
import '../../mirroring/widgets/screenshot_dialog.dart';
import '../logcat_controller.dart';
import '../widgets/column_config_dialog.dart';
import '../widgets/left_vertical_toolbar.dart';
import '../widgets/log_tab_bar.dart';
import '../widgets/log_table_view.dart';
import '../widgets/presets_dialog.dart';
import '../widgets/status_bar.dart';
import '../widgets/top_filter_bar.dart';

/// Main desktop viewport displaying the toolbar, logcat grid, and status indicators.
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
  double _mirrorWidth = 340.0;

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
      try {
        final started = await _captureService.startRecording(serial: serial);
        if (started) {
          _notify('● Recording in progress (hardware-encoded)');
        } else {
          _notify('Failed to start recording on device', isError: true);
        }
      } catch (e) {
        _notify('Start recording failed: $e', isError: true);
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
        const SingleActivator(LogicalKeyboardKey.keyT, control: true):
            _controller.addTab,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true):
            () => _controller.closeTab(_controller.activeTabId),
        const SingleActivator(LogicalKeyboardKey.tab, control: true):
            _controller.selectNextTab,
        const SingleActivator(
              LogicalKeyboardKey.tab,
              control: true,
              shift: true,
            ):
            _controller.selectPreviousTab,
        const SingleActivator(LogicalKeyboardKey.digit1, control: true):
            () => _controller.selectTabByIndex(0),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true):
            () => _controller.selectTabByIndex(1),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true):
            () => _controller.selectTabByIndex(2),
        const SingleActivator(LogicalKeyboardKey.digit4, control: true):
            () => _controller.selectTabByIndex(3),
        const SingleActivator(LogicalKeyboardKey.digit5, control: true):
            () => _controller.selectTabByIndex(4),
        const SingleActivator(LogicalKeyboardKey.backslash, control: true):
            () => _controller.toggleSplit(),
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
                    noiseMode: _controller.noiseMode,
                    onSearch: (v) => _controller.setSearch(v, immediate: false),
                    onLevel: _controller.setMinLevel,
                    onPackage: _controller.applyPackage,
                    onRegex: _controller.toggleRegex,
                    onDevice: _controller.applyDevice,
                    onNoiseMode: _controller.setNoiseMode,
                  );
                },
              ),

              // Multi-tab logcat bar (supports draggable tabs & split-view controls)
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  return LogTabBar(
                    tabs: _controller.logTabs,
                    activeTabId: _controller.activeTabId,
                    secondaryTabId: _controller.secondaryTab?.id,
                    splitAxis: _controller.splitAxis,
                    devices: _controller.devices,
                    activeDeviceSerial: _controller.activeDevice,
                    viewMode: _controller.viewMode,
                    onSelectTab: _controller.selectTab,
                    onAddTab: _controller.addTab,
                    onCloseTab: _controller.closeTab,
                    onDuplicateTab: _controller.duplicateTab,
                    onRenameTab: _controller.renameTab,
                    onCloseOtherTabs: _controller.closeOtherTabs,
                    onCloseTabsToRight: _controller.closeTabsToRight,
                    onReorderTab: _controller.reorderTab,
                    onSplitWithTab: _controller.splitWithTab,
                    onToggleSplit: _controller.toggleSplit,
                    onCloseSplit: _controller.closeSplit,
                    onClearDeviceBuffer:
                        () => _controller.clearLogs(clearDeviceBuffer: true),
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

                        // Log entries table view (single pane or resizable split panes,
                        // with drag-to-split drop target overlay).
                        Expanded(
                          child: _SplitDropArea(
                            palette: palette,
                            onDropSplit: (tabId, axis, putInPrimary) {
                              _controller.splitWithTab(
                                tabId,
                                axis,
                                putInPrimary: putInPrimary,
                              );
                            },
                            child: _buildLogViewport(palette),
                          ),
                        ),

                        // Screen Mirror split view with adjustable divider
                        ValueListenableBuilder<bool>(
                          valueListenable: _mirrorController.isOpen,
                          builder: (context, isOpen, _) {
                            if (!isOpen) return const SizedBox.shrink();
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _ResizableDivider(
                                  axis: Axis.horizontal,
                                  palette: palette,
                                  onDragDelta: (dx) {
                                    setState(() {
                                      _mirrorWidth = (_mirrorWidth - dx).clamp(
                                        240.0,
                                        640.0,
                                      );
                                    });
                                  },
                                  onReset: () => setState(() => _mirrorWidth = 340.0),
                                ),
                                SizedBox(
                                  width: _mirrorWidth,
                                  child: ScreenMirrorView(
                                    controller: _mirrorController,
                                    onClose: () => _mirrorController.setOpen(false),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),

              // Bottom status bar - rebuilds on log/connection counts of focused pane
              ListenableBuilder(
                listenable: Listenable.merge([
                  _controller,
                  _controller.primaryStatsNotifier,
                  _controller.secondaryStatsNotifier,
                ]),
                builder: (context, _) {
                  final stats =
                      (_controller.isSplit && _controller.focusedPane == 1
                              ? _controller.secondaryStatsNotifier
                              : _controller.primaryStatsNotifier)
                          .value;
                  return LogcatStatusBar(
                    connection: _controller.connection,
                    serverStatus: _controller.serverStatus,
                    activeDevice: _controller.activeDevice,
                    devices: _controller.devices,
                    appPid: _controller.appPid,
                    paused: _controller.paused,
                    autoScroll: _controller.autoScroll,
                    visibleCount: stats.visible,
                    totalCount: stats.total,
                    hiddenNoiseCount: stats.hiddenNoise,
                    reduceNoise: _controller.reduceNoise,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogViewport(AppPalette palette) {
    if (!_controller.isSplit) {
      return _buildSinglePane(
        paneIndex: 0,
        tab: _controller.primaryTab,
        palette: palette,
        showSplitHeader: false,
      );
    }

    final isHorizontal = _controller.splitAxis == LogSplitAxis.horizontal;
    const dividerExtent = 6.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalExtent =
            isHorizontal ? constraints.maxWidth : constraints.maxHeight;
        final available = (totalExtent - dividerExtent).clamp(1.0, double.infinity);
        final firstExtent = (available * _controller.splitRatio).clamp(
          120.0,
          (available - 120.0).clamp(120.0, available),
        );

        final firstPane = _buildSinglePane(
          paneIndex: 0,
          tab: _controller.primaryTab,
          palette: palette,
          showSplitHeader: true,
        );
        final secondPane = _buildSinglePane(
          paneIndex: 1,
          tab: _controller.secondaryTab!,
          palette: palette,
          showSplitHeader: true,
        );
        final divider = _ResizableDivider(
          axis: isHorizontal ? Axis.horizontal : Axis.vertical,
          palette: palette,
          onDragDelta: (delta) {
            if (available <= 0) return;
            _controller.setSplitRatio((firstExtent + delta) / available);
          },
          onReset: () => _controller.setSplitRatio(0.5),
        );

        if (isHorizontal) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: firstExtent, child: firstPane),
              divider,
              Expanded(child: secondPane),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: firstExtent, child: firstPane),
            divider,
            Expanded(child: secondPane),
          ],
        );
      },
    );
  }

  Widget _buildSinglePane({
    required int paneIndex,
    required LogTabState tab,
    required AppPalette palette,
    required bool showSplitHeader,
  }) {
    final isSecondary = paneIndex == 1;
    final isFocused = !showSplitHeader || _controller.focusedPane == paneIndex;

    final entries =
        isSecondary ? _controller.secondaryVisible : _controller.primaryVisible;
    final entriesNotifier =
        isSecondary
            ? _controller.secondaryVisibleNotifier
            : _controller.primaryVisibleNotifier;
    final statsNotifier =
        isSecondary
            ? _controller.secondaryStatsNotifier
            : _controller.primaryStatsNotifier;
    final scrollCtrl =
        isSecondary
            ? _controller.secondaryScrollController
            : _controller.primaryScrollController;
    final totalCount =
        isSecondary
            ? _controller.secondaryLines.length
            : _controller.primaryLines.length;

    final table = LogTableView(
      entries: entries,
      entriesNotifier: entriesNotifier,
      statsNotifier: statsNotifier,
      totalLinesCount: totalCount,
      columns: _controller.columns,
      wrap: tab.wrap,
      autoScroll: tab.autoScroll,
      scrollController: scrollCtrl,
      appPid: _controller.appPidForTab(tab),
      packageFilter: tab.packageFilter.trim(),
      onCopy: (entry) {
        _controller.copyLogEntry(entry, tab: tab);
        _notify('Log line copied to clipboard');
      },
      onFilterTag: (tag) {
        _controller.focusPane(paneIndex);
        _controller.setFilterTag(tag);
      },
      onFilterPackage: (pkg) {
        _controller.focusPane(paneIndex);
        _controller.setFilterPackage(pkg);
      },
      onScrollToEnd: () => _controller.scrollToEnd(paneIndex),
      onUpdateColumns: _controller.updateColumns,
    );

    if (!showSplitHeader) {
      return table;
    }

    return Listener(
      onPointerDown: (_) => _controller.focusPane(paneIndex),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: isFocused ? palette.accent.withValues(alpha: 0.7) : palette.border,
          ),
        ),
        child: Column(
          children: [
            _SplitPaneHeader(
              tab: tab,
              tabs: _controller.logTabs,
              isFocused: isFocused,
              isSecondary: isSecondary,
              palette: palette,
              onFocus: () => _controller.focusPane(paneIndex),
              onSelectTabForPane: (tabId) {
                _controller.focusPane(paneIndex);
                _controller.selectTab(tabId);
              },
              onCloseSplit: _controller.closeSplit,
            ),
            Expanded(child: table),
          ],
        ),
      ),
    );
  }
}

class _SplitPaneHeader extends StatelessWidget {
  const _SplitPaneHeader({
    required this.tab,
    required this.tabs,
    required this.isFocused,
    required this.isSecondary,
    required this.palette,
    required this.onFocus,
    required this.onSelectTabForPane,
    required this.onCloseSplit,
  });

  final LogTabState tab;
  final List<LogTabState> tabs;
  final bool isFocused;
  final bool isSecondary;
  final AppPalette palette;
  final VoidCallback onFocus;
  final ValueChanged<String> onSelectTabForPane;
  final VoidCallback onCloseSplit;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onFocus,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: isFocused ? palette.accentBg : palette.panel,
          border: Border(bottom: BorderSide(color: palette.border)),
        ),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isFocused ? palette.accent : palette.dim.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 6),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: tabs.any((t) => t.id == tab.id) ? tab.id : null,
                isDense: true,
                dropdownColor: palette.panel,
                icon: Icon(Icons.arrow_drop_down, size: 15, color: palette.dim),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isFocused ? FontWeight.w600 : FontWeight.normal,
                  color: palette.text,
                ),
                items: [
                  for (final t in tabs)
                    DropdownMenuItem<String>(
                      value: t.id,
                      child: Text(
                        t.displayTitle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) {
                  if (id != null) onSelectTabForPane(id);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  if (tab.deviceSerial != null) tab.deviceSerial!,
                  if (tab.minLevel != 'V') '${tab.minLevel}+',
                  if (tab.paused) 'PAUSED',
                ].join(' · '),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: palette.dim),
              ),
            ),
            if (isSecondary)
              Tooltip(
                message: 'Close Split Pane',
                child: InkWell(
                  onTap: onCloseSplit,
                  borderRadius: BorderRadius.circular(3),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 13, color: palette.dim),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResizableDivider extends StatefulWidget {
  const _ResizableDivider({
    required this.axis,
    required this.palette,
    required this.onDragDelta,
    required this.onReset,
  });

  final Axis axis;
  final AppPalette palette;
  final ValueChanged<double> onDragDelta;
  final VoidCallback onReset;

  @override
  State<_ResizableDivider> createState() => _ResizableDividerState();
}

class _ResizableDividerState extends State<_ResizableDivider> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final isHorizontal = widget.axis == Axis.horizontal;
    final active = _hovered || _dragging;
    final palette = widget.palette;

    return MouseRegion(
      cursor:
          isHorizontal
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: widget.onReset,
        onHorizontalDragStart:
            isHorizontal ? (_) => setState(() => _dragging = true) : null,
        onHorizontalDragUpdate:
            isHorizontal ? (d) => widget.onDragDelta(d.delta.dx) : null,
        onHorizontalDragEnd:
            isHorizontal ? (_) => setState(() => _dragging = false) : null,
        onVerticalDragStart:
            !isHorizontal ? (_) => setState(() => _dragging = true) : null,
        onVerticalDragUpdate:
            !isHorizontal ? (d) => widget.onDragDelta(d.delta.dy) : null,
        onVerticalDragEnd:
            !isHorizontal ? (_) => setState(() => _dragging = false) : null,
        child: Container(
          width: isHorizontal ? 6 : null,
          height: isHorizontal ? null : 6,
          color:
              active
                  ? palette.accent.withValues(alpha: 0.35)
                  : palette.border.withValues(alpha: 0.5),
          child: Center(
            child: Container(
              width: isHorizontal ? 2 : 28,
              height: isHorizontal ? 28 : 2,
              decoration: BoxDecoration(
                color: active ? palette.accent : palette.dim.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _DropZone { left, right, top, bottom }

class _SplitDropArea extends StatefulWidget {
  const _SplitDropArea({
    required this.palette,
    required this.onDropSplit,
    required this.child,
  });

  final AppPalette palette;
  final void Function(String tabId, LogSplitAxis axis, bool putInPrimary)
  onDropSplit;
  final Widget child;

  @override
  State<_SplitDropArea> createState() => _SplitDropAreaState();
}

class _SplitDropAreaState extends State<_SplitDropArea> {
  _DropZone? _zone;

  _DropZone _resolveZone(Offset localPos, Size size) {
    final nx = localPos.dx / size.width.clamp(1.0, double.infinity);
    final ny = localPos.dy / size.height.clamp(1.0, double.infinity);
    if (ny > 0.72 && nx > 0.18 && nx < 0.82) return _DropZone.bottom;
    if (ny < 0.28 && nx > 0.18 && nx < 0.82) return _DropZone.top;
    if (nx < 0.35) return _DropZone.left;
    return _DropZone.right;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return DragTarget<String>(
          onWillAcceptWithDetails: (details) => details.data.isNotEmpty,
          onMove: (details) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final local = box.globalToLocal(details.offset);
            final next = _resolveZone(local, size);
            if (_zone != next) setState(() => _zone = next);
          },
          onLeave: (_) {
            if (_zone != null) setState(() => _zone = null);
          },
          onAcceptWithDetails: (details) {
            final zone = _zone ?? _DropZone.right;
            setState(() => _zone = null);
            switch (zone) {
              case _DropZone.right:
                widget.onDropSplit(details.data, LogSplitAxis.horizontal, false);
              case _DropZone.left:
                widget.onDropSplit(details.data, LogSplitAxis.horizontal, true);
              case _DropZone.bottom:
                widget.onDropSplit(details.data, LogSplitAxis.vertical, false);
              case _DropZone.top:
                widget.onDropSplit(details.data, LogSplitAxis.vertical, true);
            }
          },
          builder: (context, candidateData, _) {
            final activeZone = candidateData.isNotEmpty ? _zone : null;
            return Stack(
              children: [
                widget.child,
                if (activeZone != null) _buildOverlay(activeZone, size),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildOverlay(_DropZone zone, Size size) {
    final palette = widget.palette;
    final label = switch (zone) {
      _DropZone.right => 'Drop to Split Right',
      _DropZone.left => 'Drop to Split Left',
      _DropZone.bottom => 'Drop to Split Down',
      _DropZone.top => 'Drop to Split Up',
    };

    return Positioned(
      left: zone == _DropZone.right ? size.width * 0.5 : 0,
      right: zone == _DropZone.left ? size.width * 0.5 : 0,
      top: zone == _DropZone.bottom ? size.height * 0.5 : 0,
      bottom: zone == _DropZone.top ? size.height * 0.5 : 0,
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: palette.accent, width: 2),
          ),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: palette.panel,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: palette.accent),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
