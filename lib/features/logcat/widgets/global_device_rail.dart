import 'package:flutter/material.dart';

import '../../../src/palette.dart';

AppThemeChoice _nextThemeChoice(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => AppThemeChoice.androidStudio,
  AppThemeChoice.androidStudio => AppThemeChoice.light,
  AppThemeChoice.light => AppThemeChoice.darkModern,
  AppThemeChoice.darkModern => AppThemeChoice.vsDark,
  AppThemeChoice.vsDark => AppThemeChoice.system,
};

IconData _themeChoiceIcon(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => Icons.brightness_auto,
  AppThemeChoice.androidStudio => Icons.android,
  AppThemeChoice.light => Icons.light_mode,
  AppThemeChoice.darkModern => Icons.dark_mode,
  AppThemeChoice.vsDark => Icons.contrast,
};

String _themeChoiceLabel(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => 'Theme: Auto (System)',
  AppThemeChoice.androidStudio => 'Theme: Android Studio Darcula',
  AppThemeChoice.light => 'Theme: Modern Light',
  AppThemeChoice.darkModern => 'Theme: Dark Modern',
  AppThemeChoice.vsDark => 'Theme: VS Dark',
};

/// Global device-level vertical rail for actions outside individual log tabs
/// (screenshot, screen recording, live screen mirroring, and app theme).
class GlobalDeviceRail extends StatelessWidget {
  const GlobalDeviceRail({
    super.key,
    required this.themeChoice,
    required this.onScreenshot,
    required this.onToggleRecord,
    required this.onToggleMirror,
    required this.onThemeChoice,
    this.isRecording = false,
    this.isTakingScreenshot = false,
    this.isMirrorOpen = false,
    this.recordingDuration = Duration.zero,
  });

  final AppThemeChoice themeChoice;
  final VoidCallback onScreenshot;
  final VoidCallback onToggleRecord;
  final VoidCallback onToggleMirror;
  final ValueChanged<AppThemeChoice> onThemeChoice;
  final bool isRecording;
  final bool isTakingScreenshot;
  final bool isMirrorOpen;
  final Duration recordingDuration;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: 40,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(left: BorderSide(color: palette.border)),
      ),
      child: Column(
        children: [
          _railButton(
            icon: Icons.camera_alt_outlined,
            tooltip: 'Take Screenshot (Ctrl+Shift+S)',
            onTap: onScreenshot,
            active: isTakingScreenshot,
            palette: palette,
          ),
          const SizedBox(height: 4),
          _recordButton(palette),
          const SizedBox(height: 4),
          _railButton(
            icon: Icons.screen_share_outlined,
            tooltip: 'Toggle Screen Mirror (Ctrl+Shift+M)',
            onTap: onToggleMirror,
            active: isMirrorOpen,
            palette: palette,
          ),
          const Spacer(),
          _railButton(
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

  Widget _railButton({
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
