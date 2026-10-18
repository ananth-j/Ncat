import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../../devices/models/device_info.dart';

/// Bottom status bar displaying connection state, active device, and line metrics.
class LogcatStatusBar extends StatelessWidget {
  const LogcatStatusBar({
    super.key,
    required this.connection,
    required this.serverStatus,
    required this.activeDevice,
    required this.devices,
    required this.appPid,
    required this.paused,
    required this.autoScroll,
    required this.visibleCount,
    required this.totalCount,
  });

  final String connection;
  final String serverStatus;
  final String? activeDevice;
  final List<DeviceInfo> devices;
  final int? appPid;
  final bool paused;
  final bool autoScroll;
  final int visibleCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final live = connection == 'live';
    final textStyle = TextStyle(color: palette.statusBarText, fontSize: 11);
    final dotColor = switch (connection) {
      'live' => palette.levelColor['I'],
      'connecting' => palette.levelColor['W'],
      _ => palette.levelColor['E'],
    };

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: palette.statusBarBg,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
          ),
          const SizedBox(width: 7),
          Text(live ? serverStatus : connection, style: textStyle),
          if (activeDevice != null) ...[
            const SizedBox(width: 12),
            Container(width: 1, height: 12, color: palette.border),
            const SizedBox(width: 12),
            Icon(Icons.phone_android, size: 13, color: palette.dim),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                devices
                    .firstWhere(
                      (d) => d.serial == activeDevice,
                      orElse: () => DeviceInfo(serial: activeDevice!),
                    )
                    .label,
                style: textStyle,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
          if (appPid != null) ...[
            const SizedBox(width: 12),
            Container(width: 1, height: 12, color: palette.border),
            const SizedBox(width: 12),
            Icon(Icons.android, size: 13, color: palette.dim),
            const SizedBox(width: 4),
            Text('PID: $appPid', style: textStyle),
          ],
          const Spacer(),
          if (paused) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: palette.levelColor['W']?.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'PAUSED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: palette.levelColor['W'],
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (!autoScroll) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: palette.accent.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                'SCROLL PAUSED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: palette.accent,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Text('$visibleCount of $totalCount lines', style: textStyle),
        ],
      ),
    );
  }
}
