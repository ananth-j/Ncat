import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../../logcat/logcat_controller.dart';
import '../models/device_info.dart';

/// Horizontal tab strip for switching between connected Android devices (Phase 5.1).
class DeviceTabBar extends StatelessWidget {
  const DeviceTabBar({
    super.key,
    required this.devices,
    required this.activeSerial,
    required this.viewMode,
    required this.onSelectDevice,
    required this.onToggleViewMode,
  });

  final List<DeviceInfo> devices;
  final String? activeSerial;
  final DeviceViewMode viewMode;
  final ValueChanged<String> onSelectDevice;
  final VoidCallback onToggleViewMode;

  @override
  Widget build(BuildContext context) {
    if (devices.length <= 1 && viewMode == DeviceViewMode.singleOrTabs) {
      return const SizedBox.shrink();
    }

    final palette = context.palette;

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: devices.length,
              separatorBuilder: (_, __) => const SizedBox(width: 4),
              itemBuilder: (context, i) {
                final dev = devices[i];
                final isSelected = dev.serial == activeSerial;

                return InkWell(
                  onTap: () => onSelectDevice(dev.serial),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected ? palette.bg : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: isSelected ? palette.accent : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.phone_android,
                          size: 14,
                          color: isSelected ? palette.accent : palette.dim,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          (dev.model != null && dev.model!.isNotEmpty)
                              ? dev.model!
                              : dev.serial,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight:
                                isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                            color: isSelected ? palette.text : palette.dim,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '(${dev.serial})',
                          style: TextStyle(
                            fontSize: 9,
                            color: palette.dim.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // Grid vs Tabs view mode toggle button (Phase 5.2)
          Tooltip(
            message:
                viewMode == DeviceViewMode.grid
                    ? 'Switch to Tabs view'
                    : 'Switch to Multi-Device Matrix Grid (2-4 devices)',
            child: IconButton(
              icon: Icon(
                viewMode == DeviceViewMode.grid
                    ? Icons.tab_unselected
                    : Icons.grid_view_rounded,
                size: 16,
              ),
              color:
                  viewMode == DeviceViewMode.grid
                      ? palette.accent
                      : palette.dim,
              onPressed: onToggleViewMode,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}
