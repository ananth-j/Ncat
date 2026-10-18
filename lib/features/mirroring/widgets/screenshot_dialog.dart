import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../src/palette.dart';

/// Modal dialog providing preview, disk export, and copy operations for captured screenshots.
class ScreenshotDialog extends StatelessWidget {
  const ScreenshotDialog({
    super.key,
    required this.bytes,
    required this.serial,
    required this.onSave,
  });

  final Uint8List bytes;
  final String? serial;
  final Future<void> Function(Uint8List bytes) onSave;

  static Future<void> show({
    required BuildContext context,
    required Uint8List bytes,
    String? serial,
    required Future<void> Function(Uint8List bytes) onSave,
  }) {
    return showDialog<void>(
      context: context,
      builder:
          (ctx) =>
              ScreenshotDialog(bytes: bytes, serial: serial, onSave: onSave),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: palette.border),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.photo_camera, size: 18, color: palette.accent),
                  const SizedBox(width: 8),
                  Text(
                    'Screenshot ${serial != null ? '($serial)' : ''}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: palette.text,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${(bytes.lengthInBytes / 1024).toStringAsFixed(1)} KB',
                    style: TextStyle(fontSize: 11, color: palette.dim),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(Icons.close, size: 18, color: palette.dim),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: palette.border),

            // Preview Image
            Flexible(
              child: Container(
                color: Colors.black.withValues(alpha: 0.2),
                padding: const EdgeInsets.all(16),
                alignment: Alignment.center,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              ),
            ),

            Divider(height: 1, color: palette.border),

            // Actions
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: palette.text,
                      side: BorderSide(color: palette.border),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: palette.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Save to Downloads'),
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await onSave(bytes);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
