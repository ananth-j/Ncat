import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../mirror_controller.dart';
import 'scrcpy_install_dialog.dart';

/// Interactive screen mirror view with hardware scrcpy fallback,
/// isolated RepaintBoundary rendering, and soft-keys navigation.
class ScreenMirrorView extends StatefulWidget {
  const ScreenMirrorView({super.key, required this.controller, this.onClose});

  final MirrorController controller;
  final VoidCallback? onClose;

  @override
  State<ScreenMirrorView> createState() => _ScreenMirrorViewState();
}

class _ScreenMirrorViewState extends State<ScreenMirrorView> {
  Offset? _panStart;
  DateTime? _panStartTime;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.border)),
      ),
      child: Column(
        children: [
          _buildHeader(palette),
          _buildErrorBanner(palette),
          Expanded(child: _buildScreenCanvas(palette)),
          _buildSoftKeysBar(palette),
        ],
      ),
    );
  }

  Widget _buildHeader(AppPalette palette) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.screen_share_outlined, size: 16, color: palette.accent),
          const SizedBox(width: 8),
          Expanded(
            child: ValueListenableBuilder<bool>(
              valueListenable: widget.controller.isStreaming,
              builder: (context, isStreaming, _) {
                return Text(
                  widget.controller.activeSerial ?? 'Mirror',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ),

          // FPS dropdown
          ValueListenableBuilder<int>(
            valueListenable: widget.controller.fps,
            builder: (context, fps, _) {
              return Tooltip(
                message: 'Stream Framerate Limit (Low CPU)',
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: fps,
                    isDense: true,
                    style: TextStyle(fontSize: 11, color: palette.dim),
                    dropdownColor: palette.panel,
                    icon: Icon(
                      Icons.arrow_drop_down,
                      size: 16,
                      color: palette.dim,
                    ),
                    items: const [
                      DropdownMenuItem(value: 5, child: Text('5 fps (eco)')),
                      DropdownMenuItem(value: 15, child: Text('15 fps')),
                      DropdownMenuItem(value: 30, child: Text('30 fps')),
                    ],
                    onChanged: (val) {
                      if (val != null) widget.controller.setFps(val);
                    },
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 4),

          // Launch scrcpy quick-win
          Tooltip(
            message:
                'Launch standalone scrcpy window (hardware-accelerated 60fps)',
            child: IconButton(
              icon: const Icon(Icons.open_in_new, size: 14),
              color: palette.dim,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              onPressed: () async {
                final status = await widget.controller.launchScrcpyWithStatus();
                if (!mounted) return;

                if (status == 'not_installed') {
                  await ScrcpyInstallDialog.show(
                    context: context,
                    controller: widget.controller,
                    serial: widget.controller.activeSerial,
                  );
                } else if (status != 'launched') {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        widget.controller.errorMessage.value ??
                            'Failed to launch scrcpy',
                      ),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              },
            ),
          ),

          // Refresh stream
          Tooltip(
            message: 'Reconnect mirror stream',
            child: IconButton(
              icon: const Icon(Icons.refresh, size: 14),
              color: palette.dim,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              onPressed: () => widget.controller.startStream(),
            ),
          ),

          // Collapse / close button
          if (widget.onClose != null)
            Tooltip(
              message: 'Collapse mirror view',
              child: IconButton(
                icon: const Icon(Icons.chevron_right, size: 16),
                color: palette.dim,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                onPressed: widget.onClose,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(AppPalette palette) {
    return ValueListenableBuilder<String?>(
      valueListenable: widget.controller.errorMessage,
      builder: (context, error, _) {
        if (error == null || error.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          color: const Color(0xFFE53935).withValues(alpha: 0.15),
          child: Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: Color(0xFFE53935),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  error,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFE53935),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: () => widget.controller.errorMessage.value = null,
                child: const Icon(
                  Icons.close,
                  size: 12,
                  color: Color(0xFFE53935),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildScreenCanvas(AppPalette palette) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: ValueListenableBuilder<double>(
              valueListenable: widget.controller.aspectRatio,
              builder: (context, ratio, _) {
                return AspectRatio(
                  aspectRatio: ratio,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: palette.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: RepaintBoundary(
                      child: ValueListenableBuilder<ui.Image?>(
                        valueListenable: widget.controller.currentFrame,
                        builder: (context, frame, _) {
                          if (frame == null) {
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.phone_android,
                                    size: 40,
                                    color: palette.dim.withValues(alpha: 0.4),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Waiting for device frames...',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: palette.dim.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }

                          return LayoutBuilder(
                            builder: (context, canvasConstraints) {
                              final canvasSize = Size(
                                canvasConstraints.maxWidth,
                                canvasConstraints.maxHeight,
                              );

                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (details) {
                                  widget.controller.sendTap(
                                    details.localPosition,
                                    canvasSize,
                                  );
                                },
                                onPanStart: (details) {
                                  _panStart = details.localPosition;
                                  _panStartTime = DateTime.now();
                                },
                                onPanEnd: (details) {
                                  final start = _panStart;
                                  final startTime = _panStartTime;
                                  _panStart = null;
                                  _panStartTime = null;

                                  if (start != null && startTime != null) {
                                    final duration =
                                        DateTime.now()
                                            .difference(startTime)
                                            .inMilliseconds;
                                    // Use last position or drag delta
                                    final end =
                                        start +
                                        details.velocity.pixelsPerSecond * 0.1;
                                    widget.controller.sendSwipe(
                                      start,
                                      end,
                                      canvasSize,
                                      durationMs: duration.clamp(150, 1000),
                                    );
                                  }
                                },
                                child: RawImage(
                                  image: frame,
                                  fit: BoxFit.contain,
                                  width: canvasSize.width,
                                  height: canvasSize.height,
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildSoftKeysBar(AppPalette palette) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Back button (KEYCODE_BACK = 4)
          Tooltip(
            message: 'Back (KEYCODE_BACK)',
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 14),
              color: palette.dim,
              onPressed: () => widget.controller.sendKey(4),
            ),
          ),

          // Home button (KEYCODE_HOME = 3)
          Tooltip(
            message: 'Home (KEYCODE_HOME)',
            child: IconButton(
              icon: const Icon(Icons.circle_outlined, size: 16),
              color: palette.dim,
              onPressed: () => widget.controller.sendKey(3),
            ),
          ),

          // Recents / App Switcher (KEYCODE_APP_SWITCH = 187)
          Tooltip(
            message: 'App Switcher (KEYCODE_APP_SWITCH)',
            child: IconButton(
              icon: const Icon(Icons.crop_square_rounded, size: 16),
              color: palette.dim,
              onPressed: () => widget.controller.sendKey(187),
            ),
          ),

          Container(width: 1, height: 16, color: palette.border),

          // Volume Down (KEYCODE_VOLUME_DOWN = 25)
          Tooltip(
            message: 'Volume Down',
            child: IconButton(
              icon: const Icon(Icons.volume_down_outlined, size: 15),
              color: palette.dim,
              onPressed: () => widget.controller.sendKey(25),
            ),
          ),

          // Volume Up (KEYCODE_VOLUME_UP = 24)
          Tooltip(
            message: 'Volume Up',
            child: IconButton(
              icon: const Icon(Icons.volume_up_outlined, size: 15),
              color: palette.dim,
              onPressed: () => widget.controller.sendKey(24),
            ),
          ),

          // Power (KEYCODE_POWER = 26)
          Tooltip(
            message: 'Power Button',
            child: IconButton(
              icon: const Icon(Icons.power_settings_new, size: 15),
              color: palette.dim,
              onPressed: () => widget.controller.sendKey(26),
            ),
          ),
        ],
      ),
    );
  }
}
