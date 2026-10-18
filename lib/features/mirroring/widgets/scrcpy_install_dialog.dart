import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../mirror_controller.dart';

/// Modal dialog that explains scrcpy benefits and offers a one-click automated
/// installer for the official standalone scrcpy binary release.
class ScrcpyInstallDialog extends StatefulWidget {
  const ScrcpyInstallDialog({super.key, required this.controller, this.serial});

  final MirrorController controller;
  final String? serial;

  static Future<bool?> show({
    required BuildContext context,
    required MirrorController controller,
    String? serial,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => ScrcpyInstallDialog(controller: controller, serial: serial),
    );
  }

  @override
  State<ScrcpyInstallDialog> createState() => _ScrcpyInstallDialogState();
}

class _ScrcpyInstallDialogState extends State<ScrcpyInstallDialog> {
  bool _isInstalling = false;
  String? _errorMessage;
  String _statusText = 'Ready to install';

  Future<void> _startInstall() async {
    setState(() {
      _isInstalling = true;
      _errorMessage = null;
      _statusText = 'Downloading standalone scrcpy (~11 MB)...';
    });

    try {
      final res = await widget.controller.installScrcpy();
      if (!mounted) return;

      if (res != null && res['status'] == 'ok') {
        setState(() {
          _isInstalling = false;
          _statusText = 'Installation complete! Launching scrcpy...';
        });

        // Automatically launch scrcpy for the target device
        await widget.controller.launchScrcpy(serial: widget.serial);

        if (mounted) {
          Navigator.of(context).pop(true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('scrcpy installed and launched successfully.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        setState(() {
          _isInstalling = false;
          _errorMessage =
              res?['message']?.toString() ??
              'Failed to install scrcpy. Please check your internet connection.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isInstalling = false;
        _errorMessage = 'Installation error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final errorColor =
        palette.levelColor['E'] ?? Theme.of(context).colorScheme.error;

    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: palette.border),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: palette.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.bolt, size: 20, color: palette.accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hardware-Accelerated Mirroring',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: palette.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'scrcpy 60 FPS Standalone Integration',
                          style: TextStyle(fontSize: 11, color: palette.dim),
                        ),
                      ],
                    ),
                  ),
                  if (!_isInstalling)
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      color: palette.dim,
                      onPressed: () => Navigator.of(context).pop(false),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // Description
              Text(
                'scrcpy is an open-source tool providing high-performance 60 FPS screen mirroring with near-zero host CPU overhead.',
                style: TextStyle(
                  fontSize: 12,
                  color: palette.text.withValues(alpha: 0.85),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),

              // Feature badges
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.border),
                ),
                child: Column(
                  children: [
                    _FeatureRow(
                      icon: Icons.speed,
                      title: '60 FPS Ultra-Smooth Mirroring',
                      subtitle:
                          'Direct hardware video decoding via H.264/H.265',
                      palette: palette,
                    ),
                    const SizedBox(height: 10),
                    _FeatureRow(
                      icon: Icons.memory,
                      title: '0% Host CPU Overhead',
                      subtitle: 'Runs as an isolated standalone native process',
                      palette: palette,
                    ),
                    const SizedBox(height: 10),
                    _FeatureRow(
                      icon: Icons.mouse,
                      title: 'Low-latency Touch & Keyboard',
                      subtitle:
                          'Native mouse gestures and keystroke forwarding',
                      palette: palette,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Status or Error
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: errorColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: errorColor.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 16, color: errorColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(fontSize: 11, color: errorColor),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_isInstalling) ...[
                Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          palette.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _statusText,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.accent,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  backgroundColor: palette.border,
                  valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
                  minHeight: 3,
                ),
                const SizedBox(height: 14),
              ],

              // Download notes
              if (!_isInstalling && _errorMessage == null)
                Text(
                  'Wcat will download the official standalone release (~11 MB) from GitHub and extract it into your local app data folder. No system PATH changes or admin privileges required.',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: palette.dim,
                    height: 1.3,
                  ),
                ),
              const SizedBox(height: 16),

              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (!_isInstalling)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: TextButton.styleFrom(
                        foregroundColor: palette.dim,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Cancel'),
                    ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: Icon(
                      _isInstalling ? Icons.hourglass_top : Icons.download,
                      size: 14,
                    ),
                    label: Text(
                      _isInstalling
                          ? 'Installing...'
                          : (_errorMessage != null
                              ? 'Retry Installation'
                              : 'Install scrcpy'),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.accent,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onPressed: _isInstalling ? null : _startInstall,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.palette,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: palette.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                subtitle,
                style: TextStyle(fontSize: 10, color: palette.dim),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
