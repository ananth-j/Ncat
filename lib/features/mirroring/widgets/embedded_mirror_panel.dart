import 'dart:async';
import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../mirror_controller.dart';
import '../services/scrcpy_dock_service.dart';
import 'scrcpy_install_dialog.dart';

/// Docked in-app screen mirror panel displaying a native 60 FPS hardware-accelerated
/// scrcpy window reparented inside the Wcat Flutter application layout.
class EmbeddedMirrorPanel extends StatefulWidget {
  const EmbeddedMirrorPanel({
    super.key,
    required this.controller,
    required this.serial,
    required this.onClose,
    this.panelWidth = 380,
    this.dockService,
  });

  final MirrorController controller;
  final String? serial;
  final VoidCallback onClose;
  final double panelWidth;
  final ScrcpyDockService? dockService;

  @override
  State<EmbeddedMirrorPanel> createState() => _EmbeddedMirrorPanelState();
}

class _EmbeddedMirrorPanelState extends State<EmbeddedMirrorPanel> {
  late final ScrcpyDockService _dockService;
  final GlobalKey _viewportKey = GlobalKey();

  bool _isConnecting = true;
  bool _isNotInstalled = false;
  String? _errorMessage;
  Rect? _lastBounds;

  @override
  void initState() {
    super.initState();
    _dockService = widget.dockService ?? ScrcpyDockService();
    _startAndDockMirror();
  }

  @override
  void didUpdateWidget(covariant EmbeddedMirrorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serial != widget.serial && widget.serial != null) {
      _startAndDockMirror();
    }
  }

  Future<void> _startAndDockMirror() async {
    final serial = widget.serial;
    if (serial == null) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage = 'No device connected';
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

    final title = widget.controller.getScrcpyTitle(serial);
    final status = await widget.controller.launchScrcpyWithStatus(
      serial: serial,
      borderless: true,
      customTitle: title,
    );

    if (!mounted) return;

    if (status == 'not_installed') {
      setState(() {
        _isConnecting = false;
        _isNotInstalled = true;
      });
      return;
    }

    if (status != 'launched') {
      setState(() {
        _isConnecting = false;
        _errorMessage =
            widget.controller.errorMessage.value ?? 'Failed to launch scrcpy';
      });
      return;
    }

    // Schedule docking after layout renders
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _dockToCurrentBounds(title);
    });
  }

  Future<void> _dockToCurrentBounds(String title) async {
    if (!mounted) return;
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final bounds = Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    final success = await _dockService.dock(
      windowTitle: title,
      bounds: bounds,
      devicePixelRatio: dpr,
    );

    if (!mounted) return;
    setState(() {
      _isConnecting = false;
      _lastBounds = bounds;
      if (!success) {
        _errorMessage = 'Could not dock mirror window. Click Pop Out to view.';
      }
    });
  }

  void _syncBounds() {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !mounted) return;

    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final bounds = Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);

    if (bounds != _lastBounds) {
      _lastBounds = bounds;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      _dockService.updateBounds(bounds: bounds, devicePixelRatio: dpr);
    }
  }

  void _toggleDocked() {
    if (widget.controller.isDocked.value) {
      widget.controller.isDocked.value = false;
      _dockService.undock();
    } else {
      widget.controller.isDocked.value = true;
      final serial = widget.serial;
      if (serial != null) {
        final title = widget.controller.getScrcpyTitle(serial);
        _dockToCurrentBounds(title);
      }
    }
    setState(() {});
  }

  Future<void> _handleInstallScrcpy() async {
    final serial = widget.serial;
    if (serial == null) return;
    await ScrcpyInstallDialog.show(
      context: context,
      controller: widget.controller,
      serial: serial,
    );
    if (mounted) {
      _startAndDockMirror();
    }
  }

  @override
  void dispose() {
    _dockService.close();
    widget.controller.stopScrcpy(serial: widget.serial);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBounds());

    return Container(
      width: widget.panelWidth,
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(left: BorderSide(color: palette.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Bar with device header and hardware control buttons
          _buildHeaderBar(palette),

          // Main viewport area where scrcpy is reparented
          Expanded(
            child: Stack(
              key: _viewportKey,
              children: [
                // Background canvas placeholder
                Container(
                  color:
                      Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF0F1015)
                          : const Color(0xFFE8EAF0),
                ),

                // Undocked state banner
                if (!widget.controller.isDocked.value)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.open_in_new_rounded,
                            size: 40,
                            color: palette.accent,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Mirror Window Popped Out',
                            style: TextStyle(
                              color: palette.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'scrcpy is running as a floating window.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: palette.dim, fontSize: 11),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: _toggleDocked,
                            icon: const Icon(Icons.vertical_align_bottom, size: 14),
                            label: const Text('Dock Inside Wcat'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: palette.accent,
                              side: BorderSide(color: palette.accent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Not installed state
                if (_isNotInstalled)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.screen_share_outlined,
                            size: 40,
                            color: palette.dim,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'scrcpy Not Installed',
                            style: TextStyle(
                              color: palette.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Wcat can automatically download the official standalone scrcpy binary.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: palette.dim, fontSize: 11),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _handleInstallScrcpy,
                            icon: const Icon(Icons.download, size: 14),
                            label: const Text('Install scrcpy'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: palette.accent,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Error state
                if (_errorMessage != null && !_isNotInstalled)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            size: 36,
                            color: Color(0xFFC5333D),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _errorMessage!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.text,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 14),
                          OutlinedButton(
                            onPressed: _startAndDockMirror,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Connecting state
                if (_isConnecting)
                  Container(
                    color: palette.bg.withValues(alpha: 0.9),
                    child: Center(
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
                          const SizedBox(height: 14),
                          Text(
                            'Connecting hardware mirror...',
                            style: TextStyle(
                              color: palette.text,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Zero CPU • 60 FPS • Direct3D',
                            style: TextStyle(
                              color: palette.dim,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderBar(AppPalette palette) {
    final isDocked = widget.controller.isDocked.value;

    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border, width: 1)),
      ),
      child: Row(
        children: [
          // Green active dot + Mirror title
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: Color(0xFF4EC9B0),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              widget.serial != null
                  ? 'Mirror • ${widget.serial}'
                  : 'Screen Mirror',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
          ),

          // Android Navigation Hardware Keys
          _keyButton(
            icon: Icons.arrow_back_ios_new_rounded,
            tooltip: 'Back (Keycode 4)',
            onTap: () => widget.controller.sendKey(4, serial: widget.serial),
            palette: palette,
          ),
          _keyButton(
            icon: Icons.circle_outlined,
            tooltip: 'Home (Keycode 3)',
            onTap: () => widget.controller.sendKey(3, serial: widget.serial),
            palette: palette,
          ),
          _keyButton(
            icon: Icons.crop_square_rounded,
            tooltip: 'Recent Apps (Keycode 187)',
            onTap: () => widget.controller.sendKey(187, serial: widget.serial),
            palette: palette,
          ),
          _keyButton(
            icon: Icons.power_settings_new_rounded,
            tooltip: 'Power (Keycode 26)',
            onTap: () => widget.controller.sendKey(26, serial: widget.serial),
            palette: palette,
          ),

          Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: palette.border,
          ),

          // Undock / Pop-out button
          _keyButton(
            icon:
                isDocked
                    ? Icons.open_in_new_rounded
                    : Icons.vertical_align_bottom,
            tooltip: isDocked ? 'Pop out window' : 'Dock inside',
            onTap: _toggleDocked,
            palette: palette,
          ),

          // Close button
          _keyButton(
            icon: Icons.close_rounded,
            tooltip: 'Close Mirror',
            onTap: widget.onClose,
            palette: palette,
          ),
        ],
      ),
    );
  }

  Widget _keyButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    required AppPalette palette,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(5.0),
          child: Icon(icon, size: 13, color: palette.dim),
        ),
      ),
    );
  }
}
