import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../src/palette.dart';
import '../capture_service.dart';
import '../mirror_controller.dart';
import 'scrcpy_install_dialog.dart';
import 'screenshot_dialog.dart';

/// Embedded, 100% native Flutter screen mirroring view.
/// Decodes raw H.264 video stream into a Flutter Texture widget using media_kit
/// and translates touch and gesture interactions into binary scrcpy control packets.
class EmbeddedStreamMirrorView extends StatefulWidget {
  const EmbeddedStreamMirrorView({
    super.key,
    required this.controller,
    required this.serial,
    required this.onClose,
    this.panelWidth = 380,
    this.player,
    this.videoController,
    this.captureService,
  });

  final MirrorController controller;
  final String? serial;
  final VoidCallback onClose;
  final double panelWidth;
  final Player? player;
  final VideoController? videoController;
  final CaptureService? captureService;

  @override
  State<EmbeddedStreamMirrorView> createState() =>
      _EmbeddedStreamMirrorViewState();
}

class _EmbeddedStreamMirrorViewState extends State<EmbeddedStreamMirrorView> {
  Player? _player;
  VideoController? _videoController;
  late final CaptureService _captureService;

  bool _isConnecting = true;
  bool _isNotInstalled = false;
  String? _errorMessage;

  Offset? _panStart;
  DateTime? _panStartTime;

  @override
  void initState() {
    super.initState();
    _captureService = widget.captureService ?? CaptureService();
    _initStream();
  }

  @override
  void didUpdateWidget(covariant EmbeddedStreamMirrorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serial != widget.serial && widget.serial != null) {
      _initStream();
    }
  }

  Future<void> _initStream() async {
    final serial = widget.serial;
    if (serial == null || serial.isEmpty) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage = 'No active device connected';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isConnecting = true;
        _errorMessage = null;
        _isNotInstalled = false;
      });
    }

    // 1. Launch headless scrcpy-server on device
    final status = await widget.controller.launchScrcpyWithStatus(
      serial: serial,
    );

    if (!mounted) return;

    if (status == 'not_installed') {
      setState(() {
        _isConnecting = false;
        _isNotInstalled = true;
      });
      return;
    }

    if (status != 'running' && status != 'launched') {
      setState(() {
        _isConnecting = false;
        _errorMessage =
            widget.controller.errorMessage.value ??
            'Failed to start headless scrcpy stream';
      });
      return;
    }

    // 2. Initialize media_kit Player and VideoController
    try {
      if (_player == null) {
        final player =
            widget.player ??
            Player(
              configuration: const PlayerConfiguration(
                bufferSize: 1024 * 512,
              ),
            );
        _player = player;

        final videoController =
            widget.videoController ??
            VideoController(
              player,
              configuration: const VideoControllerConfiguration(
                enableHardwareAcceleration: true,
              ),
            );
        _videoController = videoController;

        // Configure low-latency profile for raw H.264 elementary stream
        if (player.platform is NativePlayer) {
          final native = player.platform as NativePlayer;
          await native.setProperty('profile', 'low-latency');
          await native.setProperty('demuxer-lavf-format', 'h264');
          await native.setProperty('cache', 'no');
          await native.setProperty('untimed', 'yes');
          await native.setProperty('fps', '60');
          await native.setProperty('vd-lavc-threads', '1');
        }
      }

      // Open stream endpoint from Dart bridge
      final streamUrl = widget.controller.getVideoStreamUrl(serial);
      await _player?.open(Media(streamUrl), play: true);

      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage = 'Media player initialization failed: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      width: widget.panelWidth,
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(left: BorderSide(color: palette.border)),
      ),
      child: Column(
        children: [
          _buildHeader(palette),
          Expanded(child: _buildBody(palette)),
          _buildSoftKeysBar(palette),
        ],
      ),
    );
  }

  Widget _buildHeader(AppPalette palette) {
    final serial = widget.serial ?? 'No device';
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.screen_share_outlined,
            size: 16,
            color: Color(0xFF4CAF50),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Screen Mirror ($serial)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: const Color(0xFF4CAF50).withValues(alpha: 0.3),
              ),
            ),
            child: const Text(
              'H.264',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Color(0xFF4CAF50),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Take Screenshot',
            child: IconButton(
              icon: const Icon(Icons.camera_alt_outlined, size: 15),
              color: palette.dim,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => _takeScreenshot(palette),
            ),
          ),
          Tooltip(
            message: 'Close Mirror',
            child: IconButton(
              icon: const Icon(Icons.close, size: 15),
              color: palette.dim,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: widget.onClose,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppPalette palette) {
    if (_isNotInstalled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_for_offline_outlined,
                  size: 48, color: palette.accent),
              const SizedBox(height: 12),
              Text(
                'scrcpy tools required',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Install scrcpy dependencies to enable embedded video streaming.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: palette.dim),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.download, size: 14),
                label: const Text('Install Now'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.accent,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (ctx) => ScrcpyInstallDialog(
                      controller: widget.controller,
                      serial: widget.serial,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 40, color: Color(0xFFE53935)),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Color(0xFFE53935)),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 13),
                label: const Text('Retry Connection'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.text,
                  side: BorderSide(color: palette.border),
                  textStyle: const TextStyle(fontSize: 11),
                ),
                onPressed: _initStream,
              ),
            ],
          ),
        ),
      );
    }

    if (_isConnecting || _videoController == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: palette.accent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Connecting to embedded stream...',
              style: TextStyle(fontSize: 11, color: palette.dim),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: AspectRatio(
              aspectRatio: 9 / 19.5,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: LayoutBuilder(
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
                          serial: widget.serial,
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
                          final duration = DateTime.now()
                              .difference(startTime)
                              .inMilliseconds;
                          final end =
                              start + details.velocity.pixelsPerSecond * 0.1;
                          widget.controller.sendSwipe(
                            start,
                            end,
                            canvasSize,
                            durationMs: duration.clamp(150, 1000),
                            serial: widget.serial,
                          );
                        }
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Video(
                            controller: _videoController!,
                            controls: NoVideoControls,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSoftKeysBar(AppPalette palette) {
    final serial = widget.serial;
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
          // Back (KEYCODE_BACK = 4)
          Tooltip(
            message: 'Back (KEYCODE_BACK)',
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 14),
              color: palette.dim,
              onPressed: () =>
                  widget.controller.sendKey(4, serial: serial),
            ),
          ),

          // Home (KEYCODE_HOME = 3)
          Tooltip(
            message: 'Home (KEYCODE_HOME)',
            child: IconButton(
              icon: const Icon(Icons.circle_outlined, size: 16),
              color: palette.dim,
              onPressed: () =>
                  widget.controller.sendKey(3, serial: serial),
            ),
          ),

          // Recents / App Switcher (KEYCODE_APP_SWITCH = 187)
          Tooltip(
            message: 'App Switcher (KEYCODE_APP_SWITCH)',
            child: IconButton(
              icon: const Icon(Icons.crop_square_rounded, size: 16),
              color: palette.dim,
              onPressed: () =>
                  widget.controller.sendKey(187, serial: serial),
            ),
          ),

          Container(width: 1, height: 16, color: palette.border),

          // Volume Down (KEYCODE_VOLUME_DOWN = 25)
          Tooltip(
            message: 'Volume Down',
            child: IconButton(
              icon: const Icon(Icons.volume_down_outlined, size: 15),
              color: palette.dim,
              onPressed: () =>
                  widget.controller.sendKey(25, serial: serial),
            ),
          ),

          // Volume Up (KEYCODE_VOLUME_UP = 24)
          Tooltip(
            message: 'Volume Up',
            child: IconButton(
              icon: const Icon(Icons.volume_up_outlined, size: 15),
              color: palette.dim,
              onPressed: () =>
                  widget.controller.sendKey(24, serial: serial),
            ),
          ),

          // Power (KEYCODE_POWER = 26)
          Tooltip(
            message: 'Power Button',
            child: IconButton(
              icon: const Icon(Icons.power_settings_new, size: 15),
              color: palette.dim,
              onPressed: () =>
                  widget.controller.sendKey(26, serial: serial),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _takeScreenshot(AppPalette palette) async {
    final serial = widget.serial;
    if (serial == null) return;

    final bytes = await _captureService.takeScreenshot(serial: serial);
    if (!mounted) return;

    if (bytes != null) {
      ScreenshotDialog.show(
        context: context,
        bytes: bytes,
        serial: serial,
        onSave: (b) => _captureService.saveScreenshot(b, serial: serial),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to capture screenshot')),
      );
    }
  }
}
