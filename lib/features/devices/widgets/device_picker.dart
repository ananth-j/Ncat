import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../models/device_info.dart';

/// Dropdown selector for picking from available Android devices or auto-selecting.
class DevicePicker extends StatelessWidget {
  const DevicePicker({
    super.key,
    required this.devices,
    required this.pickedDevice,
    required this.onDeviceChanged,
  });

  final List<DeviceInfo> devices;
  final String? pickedDevice;
  final ValueChanged<String?> onDeviceChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final value =
        devices.any((d) => d.serial == pickedDevice) ? pickedDevice : null;

    return Container(
      width: 215,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: value,
          isDense: true,
          dropdownColor: palette.panel,
          icon: Icon(Icons.arrow_drop_down, size: 16, color: palette.dim),
          hint: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phone_android, size: 14, color: palette.dim),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  devices.isEmpty ? 'No device' : 'Auto-select',
                  style: TextStyle(fontSize: 12, color: palette.dim),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: devices.isNotEmpty
                          ? palette.levelColor['I']
                          : palette.dim,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('Auto-select',
                      style: TextStyle(fontSize: 12, color: palette.text)),
                ],
              ),
            ),
            for (final d in devices)
              DropdownMenuItem<String?>(
                value: d.serial,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: d.authorized
                            ? palette.levelColor['I']
                            : palette.levelColor['W'],
                      ),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        d.label,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 12,
                          color: d.authorized ? palette.text : palette.dim,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          onChanged: devices.isEmpty ? null : onDeviceChanged,
        ),
      ),
    );
  }
}
