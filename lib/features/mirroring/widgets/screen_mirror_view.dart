import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../src/palette.dart';
import '../mirror_controller.dart';
import 'scrcpy_install_dialog.dart';

/// Hosts scrcpy's native window in the mirror pane when the platform supports it.
class ScreenMirrorView extends StatefulWidget {
  const ScreenMirrorView({super.key, required this.controller, this.onClose});

  final MirrorController controller;
  final VoidCallback? onClose;

  @override
  State<ScreenMirrorView> createState() => _ScreenMirrorViewState();
}

class _ScreenMirrorViewState extends State<ScreenMirrorView> {
  static const _embedChannel = MethodChannel('ThruWire/scrcpy_embed');
  final GlobalKey _canvasKey = GlobalKey();
  Timer? _embedTimer;
  bool _syncingEmbedBounds = false;

  @override
  void initState() {
    super.initState();
    _embedTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _syncScrcpyBounds();
    });
  }

  Future<void> _syncScrcpyBounds() async {
    final controller = widget.controller;
    if (_syncingEmbedBounds || !controller.isScrcpyEmbedded.value) return;

    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final serial = controller.activeSerial;
    if (box == null || !box.hasSize || serial == null) return;

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final origin = box.localToGlobal(Offset.zero);
    _syncingEmbedBounds = true;
    try {
      await _embedChannel.invokeMethod<bool>('attach', {
        'title': 'ThruWire mirror - $serial',
        'x': (origin.dx * dpr).round(),
        'y': (origin.dy * dpr).round(),
        'width': (box.size.width * dpr).round(),
        'height': (box.size.height * dpr).round(),
      });
    } on PlatformException catch (error) {
      controller.errorMessage.value =
          'Could not embed scrcpy: ${error.message}';
    } on MissingPluginException {
      controller.errorMessage.value =
          'This app build cannot embed the scrcpy window.';
      controller.isScrcpyEmbedded.value = false;
    } finally {
      _syncingEmbedBounds = false;
    }
  }

  @override
  void dispose() {
    _embedTimer?.cancel();
    super.dispose();
  }

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
          _buildErrorBanner(),
          Expanded(child: _buildCanvas(palette)),
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
            child: Text(
              widget.controller.activeSerial ?? 'Scrcpy',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ValueListenableBuilder<String?>(
            valueListenable: widget.controller.errorMessage,
            builder:
                (context, error, _) => ValueListenableBuilder<bool>(
                  valueListenable: widget.controller.isScrcpyRunning,
                  builder:
                      (context, running, _) => Text(
                        running
                            ? 'SCRCPY'
                            : error == null
                            ? 'STARTING'
                            : 'ERROR',
                        style: TextStyle(
                          fontSize: 9,
                          color:
                              running
                                  ? const Color(0xFF43A047)
                                  : error == null
                                  ? palette.dim
                                  : const Color(0xFFE53935),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                ),
          ),
          if (widget.onClose != null)
            IconButton(
              tooltip: 'Collapse mirror pane',
              icon: const Icon(Icons.chevron_right, size: 16),
              color: palette.dim,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              onPressed: widget.onClose,
            ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner() {
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
              TextButton(
                onPressed: _launchScrcpy,
                child: const Text('Retry', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCanvas(AppPalette palette) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: AspectRatio(
          aspectRatio: 9 / 19.5,
          child: Container(
            key: _canvasKey,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: palette.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: ValueListenableBuilder<bool>(
              valueListenable: widget.controller.isScrcpyEmbedded,
              builder: (context, embedded, _) {
                if (embedded) return const SizedBox.expand();
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      widget.controller.isScrcpyRunning.value
                          ? 'scrcpy is running in its own window.'
                          : 'Starting scrcpy…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.dim, fontSize: 12),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _launchScrcpy() async {
    widget.controller.errorMessage.value = null;
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
            widget.controller.errorMessage.value ?? 'Failed to launch scrcpy',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}
