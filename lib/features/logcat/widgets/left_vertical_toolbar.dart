import 'package:flutter/material.dart';

import '../../../src/palette.dart';

AppThemeChoice _nextThemeChoice(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => AppThemeChoice.light,
  AppThemeChoice.light => AppThemeChoice.darkModern,
  AppThemeChoice.darkModern => AppThemeChoice.vsDark,
  AppThemeChoice.vsDark => AppThemeChoice.system,
};

IconData _themeChoiceIcon(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => Icons.brightness_auto,
  AppThemeChoice.light => Icons.light_mode,
  AppThemeChoice.darkModern => Icons.dark_mode,
  AppThemeChoice.vsDark => Icons.contrast,
};

String _themeChoiceLabel(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => 'Theme: Auto (System)',
  AppThemeChoice.light => 'Theme: Modern Light',
  AppThemeChoice.darkModern => 'Theme: Dark Modern',
  AppThemeChoice.vsDark => 'Theme: VS Dark',
};

/// Left-hand vertical toolbar for quick actions (pause, clear, wrap, export, presets, theme).
class LeftVerticalToolbar extends StatelessWidget {
  const LeftVerticalToolbar({
    super.key,
    required this.paused,
    required this.wrap,
    required this.atBottom,
    required this.themeChoice,
    required this.onPause,
    required this.onWrap,
    required this.onScrollToEnd,
    required this.onScrollToTop,
    required this.onClear,
    required this.onRestart,
    required this.onExport,
    required this.onPresets,
    required this.onConfigureColumns,
    required this.onThemeChoice,
    this.onScreenshot,
    this.onToggleRecord,
    this.onToggleMirror,
    this.isRecording = false,
    this.isTakingScreenshot = false,
    this.isMirrorOpen = false,
    this.recordingDuration = Duration.zero,
  });

  final bool paused;
  final bool wrap;
  final bool atBottom;
  final AppThemeChoice themeChoice;
  final VoidCallback onPause;
  final VoidCallback onWrap;
  final VoidCallback onScrollToEnd;
  final VoidCallback onScrollToTop;
  final VoidCallback onClear;
  final VoidCallback onRestart;
  final VoidCallback onExport;
  final VoidCallback onPresets;
  final VoidCallback onConfigureColumns;
  final ValueChanged<AppThemeChoice> onThemeChoice;
  final VoidCallback? onScreenshot;
  final VoidCallback? onToggleRecord;
  final VoidCallback? onToggleMirror;
  final bool isRecording;
  final bool isTakingScreenshot;
  final bool isMirrorOpen;
  final Duration recordingDuration;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: 42,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(right: BorderSide(color: palette.border)),
      ),
      child: Column(
        children: [
          // Clear Logcat
          _toolButton(
            icon: Icons.delete_sweep_outlined,
            tooltip: 'Clear Logcat (Ctrl+L)',
            onTap: onClear,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Pause / Resume
          _toolButton(
            icon: paused ? Icons.play_arrow : Icons.pause,
            tooltip: paused ? 'Resume Logcat' : 'Pause Logcat',
            onTap: onPause,
            active: paused,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Scroll to the end
          _toolButton(
            icon: Icons.arrow_downward,
            tooltip: 'Scroll to the end',
            onTap: onScrollToEnd,
            active: atBottom,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Scroll to the top
          _toolButton(
            icon: Icons.arrow_upward,
            tooltip: 'Scroll to the top',
            onTap: onScrollToTop,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Soft-wrap lines
          _toolButton(
            icon: Icons.wrap_text,
            tooltip: 'Soft-wrap lines',
            onTap: onWrap,
            active: wrap,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Configure visible columns / formatting
          _toolButton(
            icon: Icons.view_column_outlined,
            tooltip: 'Configure Columns / Log Format',
            onTap: onConfigureColumns,
            palette: palette,
          ),
          const SizedBox(height: 6),
          Container(width: 24, height: 1, color: palette.border),
          const SizedBox(height: 6),

          // Filter Presets
          _toolButton(
            icon: Icons.bookmark_outline,
            tooltip: 'Filter Presets',
            onTap: onPresets,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Export Logs
          _toolButton(
            icon: Icons.download,
            tooltip: 'Export Logs',
            onTap: onExport,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Restart ADB
          _toolButton(
            icon: Icons.refresh,
            tooltip: 'Restart ADB',
            onTap: onRestart,
            palette: palette,
          ),
          const SizedBox(height: 6),
          Container(width: 24, height: 1, color: palette.border),
          const SizedBox(height: 6),

          // Screenshot (Phase 3)
          if (onScreenshot != null) ...[
            _toolButton(
              icon: Icons.camera_alt_outlined,
              tooltip: 'Take Screenshot (Ctrl+Shift+S)',
              onTap: onScreenshot!,
              active: isTakingScreenshot,
              palette: palette,
            ),
            const SizedBox(height: 4),
          ],

          // Screen Record (Phase 3)
          if (onToggleRecord != null) ...[
            _recordButton(palette),
            const SizedBox(height: 4),
          ],

          // Screen Mirror (Phase 4)
          if (onToggleMirror != null) ...[
            _toolButton(
              icon: Icons.screen_share_outlined,
              tooltip: 'Screen Mirror (scrcpy 60fps) (Ctrl+Shift+M)',
              onTap: onToggleMirror!,
              active: isMirrorOpen,
              palette: palette,
            ),
            const SizedBox(height: 4),
          ],

          const Spacer(),

          // Theme switcher
          _toolButton(
            icon: _themeChoiceIcon(themeChoice),
            tooltip: _themeChoiceLabel(themeChoice),
            onTap: () => onThemeChoice(_nextThemeChoice(themeChoice)),
            palette: palette,
          ),
          const SizedBox(height: 2),
        ],
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
        width: 32,
        height: 32,
        child: IconButton(
          padding: EdgeInsets.zero,
          icon: Icon(
            icon,
            size: 16,
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

  Widget _recordButton(AppPalette palette) {
    final minutes = recordingDuration.inMinutes.toString().padLeft(2, '0');
    final seconds = (recordingDuration.inSeconds % 60).toString().padLeft(
      2,
      '0',
    );
    final isWarning = recordingDuration.inSeconds >= 160;
    final tooltip =
        isRecording
            ? '● REC $minutes:$seconds${isWarning ? ' (Approaching 3m limit!)' : ' (Max 3m)'} — Click to Stop (Ctrl+Shift+R)'
            : 'Record Screen (Ctrl+Shift+R)';

    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          padding: EdgeInsets.zero,
          icon: Icon(
            isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
            size: 16,
            color: isRecording ? const Color(0xFFE53935) : palette.dim,
          ),
          style: IconButton.styleFrom(
            backgroundColor:
                isRecording
                    ? const Color(0xFFE53935).withValues(alpha: 0.15)
                    : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: BorderSide(
                color:
                    isRecording ? const Color(0xFFE53935) : Colors.transparent,
              ),
            ),
          ),
          onPressed: onToggleRecord,
        ),
      ),
    );
  }
}
