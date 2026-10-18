import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../src/palette.dart';
import '../../devices/models/device_info.dart';
import '../../devices/widgets/device_picker.dart';

/// Top horizontal bar providing device, process, search, and severity filters.
class TopFilterBar extends StatelessWidget {
  const TopFilterBar({
    super.key,
    required this.searchCtrl,
    required this.pkgCtrl,
    required this.minLevel,
    required this.useRegex,
    required this.appPid,
    required this.devices,
    required this.pickedDevice,
    required this.onSearch,
    required this.onLevel,
    required this.onPackage,
    required this.onRegex,
    required this.onDevice,
  });

  final TextEditingController searchCtrl;
  final TextEditingController pkgCtrl;
  final String minLevel;
  final bool useRegex;
  final int? appPid;
  final List<DeviceInfo> devices;
  final String? pickedDevice;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onLevel;
  final VoidCallback onPackage;
  final VoidCallback onRegex;
  final ValueChanged<String?> onDevice;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          // Device selector dropdown
          DevicePicker(
            devices: devices,
            pickedDevice: pickedDevice,
            onDeviceChanged: onDevice,
          ),
          const SizedBox(width: 8),

          // Process / package filter field
          _processField(palette),
          const SizedBox(width: 8),

          // Unified search input with regex and clear
          _searchField(palette),
          const SizedBox(width: 8),

          // Level dropdown (Verbose, Debug, Info, Warn, Error, Assert)
          _levelDropdown(palette),
        ],
      ),
    );
  }

  Widget _processField(AppPalette palette) {
    return SizedBox(
      height: 32,
      width: 185,
      child: TextField(
        controller: pkgCtrl,
        onSubmitted: (_) => onPackage(),
        style: TextStyle(fontSize: 12, color: palette.text),
        decoration: InputDecoration(
          hintText: 'package:mine or pkg',
          hintStyle: TextStyle(fontSize: 12, color: palette.dim),
          filled: true,
          fillColor: palette.bg,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          prefixIcon: Icon(Icons.phone_android, size: 13, color: palette.dim),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 26, minHeight: 26),
          suffixIconConstraints:
              const BoxConstraints(minWidth: 26, minHeight: 26),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pkgCtrl.text.isNotEmpty)
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 20, minHeight: 20),
                  icon: Icon(Icons.close, size: 12, color: palette.dim),
                  onPressed: () {
                    pkgCtrl.clear();
                    onPackage();
                  },
                )
              else if (appPid != null)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: palette.accentBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$appPid',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: palette.accent,
                    ),
                  ),
                ),
            ],
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: palette.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: palette.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: palette.accent),
          ),
        ),
      ),
    );
  }

  Widget _searchField(AppPalette palette) {
    return Expanded(
      child: SizedBox(
        height: 32,
        child: TextField(
          controller: searchCtrl,
          onChanged: onSearch,
          style: TextStyle(fontSize: 12, color: palette.text),
          decoration: InputDecoration(
            hintText: 'Filter (tag, message, or text)...',
            hintStyle: TextStyle(fontSize: 12, color: palette.dim),
            filled: true,
            fillColor: palette.bg,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            prefixIcon: Icon(Icons.search, size: 14, color: palette.dim),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 26, minHeight: 26),
            suffixIconConstraints:
                const BoxConstraints(minWidth: 60, minHeight: 26),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: 'Toggle Regex (.*)',
                  child: InkWell(
                    onTap: onRegex,
                    borderRadius: BorderRadius.circular(3),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color:
                            useRegex ? palette.accentBg : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: useRegex ? palette.accent : Colors.transparent,
                        ),
                      ),
                      child: Text(
                        '.*',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: useRegex ? palette.accent : palette.dim,
                        ),
                      ),
                    ),
                  ),
                ),
                if (searchCtrl.text.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Clear search',
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 20, minHeight: 20),
                      icon: Icon(Icons.close, size: 12, color: palette.dim),
                      onPressed: () {
                        searchCtrl.clear();
                        onSearch('');
                      },
                    ),
                  ),
                ],
                const SizedBox(width: 6),
              ],
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: palette.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: palette.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: palette.accent),
            ),
          ),
        ),
      ),
    );
  }

  Widget _levelDropdown(AppPalette palette) {
    return Container(
      width: 135,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: minLevel,
          isDense: true,
          dropdownColor: palette.panel,
          icon: Icon(Icons.arrow_drop_down, size: 16, color: palette.dim),
          items: kLevels.map((l) {
            final col = palette.levelColor[l] ?? palette.dim;
            return DropdownMenuItem<String>(
              value: l,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: col,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    kLevelNames[l] ?? l,
                    style: TextStyle(fontSize: 12, color: palette.text),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: (v) {
            if (v != null) onLevel(v);
          },
        ),
      ),
    );
  }
}
