import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../src/palette.dart';
import '../../mirroring/capture_service.dart';
import '../../mirroring/mirror_controller.dart';
import '../../mirroring/widgets/multi_screen_grid.dart';
import '../../mirroring/widgets/screen_mirror_view.dart';
import '../../mirroring/widgets/screenshot_dialog.dart';
import '../logcat_controller.dart';
import '../widgets/global_device_rail.dart';
import '../widgets/log_tab_bar.dart';
import '../widgets/log_tab_pane.dart';
import '../widgets/status_bar.dart';

/// Main desktop viewport displaying the multi-tab Logcat console, optional
/// split panes, and global device mirroring/capture rail.
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

  Future<void> _handleExportTab(String tabId) async {
    try {
      final result = await _controller.exportLogsForTab(tabId);
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
              // Top Logcat tab bar (draggable tabs, new tab '+', split & grid controls)
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

              // Main viewport area: MultiScreenGrid or self-contained LogTabPanes + global Mirror/Device Rail
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
                        // Individual tab viewport (each tab owns its own filter bar,
                        // log toolbar, log table, and status counters)
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

                        // Global Screen Mirror split panel (independent of individual log tabs)
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

                        // Global Device Actions Rail (Screenshot, Record, Mirror, Theme)
                        ListenableBuilder(
                          listenable: Listenable.merge([
                            _captureService.isRecording,
                            _captureService.recordingDuration,
                            _captureService.isTakingScreenshot,
                            _mirrorController.isOpen,
                          ]),
                          builder: (context, _) {
                            return GlobalDeviceRail(
                              themeChoice: widget.themeChoice,
                              onScreenshot: _handleScreenshot,
                              onToggleRecord: _handleToggleRecord,
                              onToggleMirror:
                                  () => _mirrorController.toggleOpen(
                                    serial: _controller.activeDevice,
                                  ),
                              onThemeChoice: widget.onThemeChoice,
                              isMirrorOpen: _mirrorController.isOpen.value,
                              isRecording: _captureService.isRecording.value,
                              recordingDuration:
                                  _captureService.recordingDuration.value,
                              isTakingScreenshot:
                                  _captureService.isTakingScreenshot.value,
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),

              // Bottom global status bar
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
      return LogTabPane(
        key: ValueKey('pane_0_${_controller.primaryTab.id}'),
        controller: _controller,
        tab: _controller.primaryTab,
        paneIndex: 0,
        isSplit: false,
        isFocused: true,
        isSecondary: false,
        onNotify: _notify,
        onExportTab: _handleExportTab,
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

        final firstPane = LogTabPane(
          key: ValueKey('pane_0_${_controller.primaryTab.id}'),
          controller: _controller,
          tab: _controller.primaryTab,
          paneIndex: 0,
          isSplit: true,
          isFocused: _controller.focusedPane == 0,
          isSecondary: false,
          onNotify: _notify,
          onExportTab: _handleExportTab,
        );
        final secondPane = LogTabPane(
          key: ValueKey('pane_1_${_controller.secondaryTab!.id}'),
          controller: _controller,
          tab: _controller.secondaryTab!,
          paneIndex: 1,
          isSplit: true,
          isFocused: _controller.focusedPane == 1,
          isSecondary: true,
          onNotify: _notify,
          onExportTab: _handleExportTab,
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
                color:
                    active ? palette.accent : palette.dim.withValues(alpha: 0.5),
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
