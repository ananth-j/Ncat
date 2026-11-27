import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../src/palette.dart';
import '../../devices/models/device_info.dart';
import '../../devices/widgets/device_picker.dart';
import '../models/noise_filter.dart';

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
    this.noiseMode = NoiseFilterMode.reduce,
    this.onNoiseMode,
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
  final NoiseFilterMode noiseMode;
  final ValueChanged<NoiseFilterMode>? onNoiseMode;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 700;
        return Container(
          height: isCompact ? 86 : 48,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: palette.panel,
            border: Border(bottom: BorderSide(color: palette.border)),
          ),
          child:
              isCompact
                  ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: DevicePicker(
                              devices: devices,
                              pickedDevice: pickedDevice,
                              onDeviceChanged: onDevice,
                              expanded: true,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            flex: 3,
                            child: _processField(palette, width: double.infinity),
                          ),
                          const SizedBox(width: 6),
                          _levelDropdown(palette, width: 112),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _searchField(palette),
                          const SizedBox(width: 6),
                          _noiseField(palette, compact: true),
                        ],
                      ),
                    ],
                  )
                  : Row(
                    children: [
                      DevicePicker(
                        devices: devices,
                        pickedDevice: pickedDevice,
                        onDeviceChanged: onDevice,
                      ),
                      const SizedBox(width: 8),
                      _processField(palette),
                      const SizedBox(width: 8),
                      _noiseField(palette),
                      const SizedBox(width: 8),
                      _searchField(palette),
                      const SizedBox(width: 8),
                      _levelDropdown(palette),
                    ],
                  ),
        );
      },
    );
  }

  Widget _noiseField(AppPalette palette, {bool compact = false}) {
    final isReduced = noiseMode == NoiseFilterMode.reduce;
    final isOnlyNoise = noiseMode == NoiseFilterMode.onlyNoise;

    final Color activeColor = isReduced
        ? palette.accent
        : (isOnlyNoise
            ? (palette.levelColor['W'] ?? Colors.orange)
            : palette.dim);
    final Color activeBg = isReduced
        ? palette.accentBg
        : (isOnlyNoise
            ? (palette.levelColor['W'] ?? Colors.orange).withValues(alpha: 0.15)
            : palette.bg);

    return PopupMenuButton<NoiseFilterMode>(
      tooltip: 'Filter out repetitive Android system & daemon noise',
      initialValue: noiseMode,
      onSelected: onNoiseMode,
      color: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: palette.border),
      ),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: NoiseFilterMode.reduce,
          child: Row(
            children: [
              Icon(Icons.cleaning_services, size: 14, color: palette.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Reduce Noise (Default)',
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.text,
                        fontWeight:
                            isReduced ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    Text(
                      'Hides low-level OS, Wi-Fi, BT & compositor spam',
                      style: TextStyle(fontSize: 10, color: palette.dim),
                    ),
                  ],
                ),
              ),
              if (isReduced)
                Icon(Icons.check, size: 14, color: palette.accent),
            ],
          ),
        ),
        PopupMenuItem(
          value: NoiseFilterMode.showAll,
          child: Row(
            children: [
              Icon(Icons.format_list_bulleted, size: 14, color: palette.dim),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Show All (Include Noise)',
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.text,
                        fontWeight: noiseMode == NoiseFilterMode.showAll
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    Text(
                      'Shows raw unfiltered logcat stream',
                      style: TextStyle(fontSize: 10, color: palette.dim),
                    ),
                  ],
                ),
              ),
              if (noiseMode == NoiseFilterMode.showAll)
                Icon(Icons.check, size: 14, color: palette.accent),
            ],
          ),
        ),
        PopupMenuItem(
          value: NoiseFilterMode.onlyNoise,
          child: Row(
            children: [
              Icon(
                Icons.filter_alt,
                size: 14,
                color: palette.levelColor['W'] ?? Colors.orange,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Only Noise',
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.text,
                        fontWeight:
                            isOnlyNoise ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    Text(
                      'Inspect filtered system chatter and daemons',
                      style: TextStyle(fontSize: 10, color: palette.dim),
                    ),
                  ],
                ),
              ),
              if (isOnlyNoise)
                Icon(
                  Icons.check,
                  size: 14,
                  color: palette.levelColor['W'] ?? Colors.orange,
                ),
            ],
          ),
        ),
      ],
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: activeBg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: (isReduced || isOnlyNoise) ? activeColor : palette.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isReduced
                  ? Icons.cleaning_services
                  : (isOnlyNoise ? Icons.filter_alt : Icons.format_list_bulleted),
              size: 13,
              color: activeColor,
            ),
            const SizedBox(width: 6),
            Text(
              compact
                  ? (isReduced ? 'Reduced' : (isOnlyNoise ? 'Noise' : 'All'))
                  : (isReduced
                      ? 'Noise: Reduced'
                      : (isOnlyNoise ? 'Noise: Only' : 'Noise: All')),
              style: TextStyle(
                fontSize: 12,
                fontWeight: (isReduced || isOnlyNoise)
                    ? FontWeight.w600
                    : FontWeight.w400,
                color: (isReduced || isOnlyNoise) ? activeColor : palette.text,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.arrow_drop_down, size: 14, color: palette.dim),
          ],
        ),
      ),
    );
  }

  Widget _processField(AppPalette palette, {double width = 185}) {
    return SizedBox(
      height: 32,
      width: width,
      child: TextField(
        expands: true,
        minLines: null,
        maxLines: null,
        controller: pkgCtrl,
        onSubmitted: (_) => onPackage(),
        style: TextStyle(fontSize: 12, color: palette.text),
        decoration: InputDecoration(
          constraints: const BoxConstraints.tightFor(height: 32),
          hintText: 'package : mine',
          hintStyle: TextStyle(fontSize: 12, color: palette.dim),
          filled: true,
          fillColor: palette.bg,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 7,
          ),
          prefixIcon: Icon(Icons.phone_android, size: 13, color: palette.dim),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 26,
            minHeight: 26,
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 26,
            minHeight: 26,
          ),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pkgCtrl.text.isNotEmpty)
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 20,
                    minHeight: 20,
                  ),
                  icon: Icon(Icons.close, size: 12, color: palette.dim),
                  onPressed: () {
                    pkgCtrl.clear();
                    onPackage();
                  },
                )
              else if (appPid != null)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
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
          expands: true,
          minLines: null,
          maxLines: null,
          controller: searchCtrl,
          onChanged: onSearch,
          style: TextStyle(fontSize: 12, color: palette.text),
          decoration: InputDecoration(
            constraints: const BoxConstraints.tightFor(height: 32),
            hintText: 'tag:MainActivity level:ERROR message:failed',
            hintStyle: TextStyle(fontSize: 12, color: palette.dim),
            filled: true,
            fillColor: palette.bg,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 7,
            ),
            prefixIcon: Icon(Icons.search, size: 14, color: palette.dim),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 26,
              minHeight: 26,
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 60,
              minHeight: 26,
            ),
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
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: useRegex ? palette.accentBg : Colors.transparent,
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
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
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

  Widget _levelDropdown(AppPalette palette, {double width = 135}) {
    return Container(
      width: width,
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
          isExpanded: true,
          dropdownColor: palette.panel,
          icon: Icon(Icons.arrow_drop_down, size: 16, color: palette.dim),
          items:
              kLevels.map((l) {
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
                      Flexible(
                        child: Text(
                          kLevelNames[l] ?? l,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: palette.text),
                        ),
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
