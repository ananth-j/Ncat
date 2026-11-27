import 'package:flutter/material.dart';

import '../../../src/palette.dart';

/// Per-tab vertical action toolbar placed inside each Logcat tab pane
/// (clear, pause, scroll, wrap, columns, presets, export, restart).
class LogTabToolbar extends StatelessWidget {
  const LogTabToolbar({
    super.key,
    required this.paused,
    required this.wrap,
    required this.atBottom,
    required this.onPause,
    required this.onWrap,
    required this.onScrollToEnd,
    required this.onScrollToTop,
    required this.onClear,
    required this.onRestart,
    required this.onExport,
    required this.onPresets,
    required this.onConfigureColumns,
  });

  final bool paused;
  final bool wrap;
  final bool atBottom;
  final VoidCallback onPause;
  final VoidCallback onWrap;
  final VoidCallback onScrollToEnd;
  final VoidCallback onScrollToTop;
  final VoidCallback onClear;
  final VoidCallback onRestart;
  final VoidCallback onExport;
  final VoidCallback onPresets;
  final VoidCallback onConfigureColumns;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: 38,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(right: BorderSide(color: palette.border)),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            _toolButton(
              icon: Icons.delete_sweep_outlined,
              tooltip: 'Clear Tab Logs (Ctrl+L)',
              onTap: onClear,
              palette: palette,
            ),
            const SizedBox(height: 4),
            _toolButton(
              icon: paused ? Icons.play_arrow : Icons.pause,
              tooltip: paused ? 'Resume Tab Logcat' : 'Pause Tab Logcat',
              onTap: onPause,
              active: paused,
              palette: palette,
            ),
            const SizedBox(height: 4),
            _toolButton(
              icon: Icons.arrow_downward,
              tooltip: 'Scroll to the end',
              onTap: onScrollToEnd,
              active: atBottom,
              palette: palette,
            ),
            const SizedBox(height: 4),
            _toolButton(
              icon: Icons.arrow_upward,
              tooltip: 'Scroll to the top',
              onTap: onScrollToTop,
              palette: palette,
            ),
            const SizedBox(height: 4),
            _toolButton(
              icon: Icons.wrap_text,
              tooltip: 'Soft-wrap lines',
              onTap: onWrap,
              active: wrap,
              palette: palette,
            ),
            const SizedBox(height: 4),
            _toolButton(
              icon: Icons.view_column_outlined,
              tooltip: 'Configure Columns / Log Format',
              onTap: onConfigureColumns,
              palette: palette,
            ),
            const SizedBox(height: 6),
            Container(width: 22, height: 1, color: palette.border),
            const SizedBox(height: 6),
            _toolButton(
              icon: Icons.bookmark_outline,
              tooltip: 'Filter Presets',
              onTap: onPresets,
              palette: palette,
            ),
            const SizedBox(height: 4),
            _toolButton(
              icon: Icons.download,
              tooltip: 'Export Tab Logs',
              onTap: onExport,
              palette: palette,
            ),
            const SizedBox(height: 4),
            _toolButton(
              icon: Icons.refresh,
              tooltip: 'Restart ADB Logcat',
              onTap: onRestart,
              palette: palette,
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
    required AppPalette palette,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 30,
        height: 30,
        child: IconButton(
          padding: EdgeInsets.zero,
          icon: Icon(
            icon,
            size: 15,
            color: active ? palette.accent : palette.dim,
          ),
          style: IconButton.styleFrom(
            backgroundColor: active ? palette.accentBg : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: BorderSide(
                color: active ? palette.accent : Colors.transparent,
              ),
            ),
          ),
          onPressed: onTap,
        ),
      ),
    );
  }
}
