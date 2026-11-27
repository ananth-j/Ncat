import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../../devices/device_controller.dart';
import '../../devices/models/device_info.dart';
import '../models/log_tab_state.dart';

/// Android Studio Logcat-style horizontal tab bar supporting multiple
/// independent log views for a single device or across multiple devices.
class LogTabBar extends StatelessWidget {
  const LogTabBar({
    super.key,
    required this.tabs,
    required this.activeTabId,
    required this.devices,
    required this.activeDeviceSerial,
    required this.viewMode,
    required this.onSelectTab,
    required this.onAddTab,
    required this.onCloseTab,
    required this.onDuplicateTab,
    required this.onRenameTab,
    required this.onCloseOtherTabs,
    required this.onCloseTabsToRight,
    required this.onToggleViewMode,
    this.onClearDeviceBuffer,
  });

  final List<LogTabState> tabs;
  final String activeTabId;
  final List<DeviceInfo> devices;
  final String? activeDeviceSerial;
  final DeviceViewMode viewMode;
  final ValueChanged<String> onSelectTab;
  final VoidCallback onAddTab;
  final ValueChanged<String> onCloseTab;
  final ValueChanged<String> onDuplicateTab;
  final void Function(String tabId, String newTitle) onRenameTab;
  final ValueChanged<String> onCloseOtherTabs;
  final ValueChanged<String> onCloseTabsToRight;
  final VoidCallback onToggleViewMode;
  final VoidCallback? onClearDeviceBuffer;

  String? _deviceShortLabel(String? serial) {
    if (serial == null || devices.length <= 1) return null;
    for (final d in devices) {
      if (d.serial == serial) {
        return (d.model != null && d.model!.isNotEmpty) ? d.model! : d.serial;
      }
    }
    return serial;
  }

  Future<void> _promptRename(
    BuildContext context,
    LogTabState tab,
    AppPalette palette,
  ) async {
    final ctrl = TextEditingController(text: tab.displayTitle);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: palette.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: palette.border),
          ),
          title: Text(
            'Rename Log Tab',
            style: TextStyle(fontSize: 14, color: palette.text),
          ),
          content: SizedBox(
            width: 280,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              style: TextStyle(fontSize: 13, color: palette.text),
              decoration: InputDecoration(
                hintText: 'Tab name (leave blank for auto)',
                hintStyle: TextStyle(fontSize: 12, color: palette.dim),
                filled: true,
                fillColor: palette.bg,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: palette.border),
                ),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Cancel', style: TextStyle(color: palette.dim)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: palette.accent),
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (result != null) {
      onRenameTab(tab.id, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final canClose = tabs.length > 1;
    final showGridButton =
        devices.length > 1 || viewMode == DeviceViewMode.grid;

    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: 3),
              itemCount: tabs.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 4),
              itemBuilder: (context, i) {
                if (i == tabs.length) {
                  return Tooltip(
                    message: 'New Log Tab (Ctrl+T)',
                    child: InkWell(
                      onTap: onAddTab,
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        width: 26,
                        height: 26,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.transparent),
                        ),
                        child: Icon(Icons.add, size: 16, color: palette.dim),
                      ),
                    ),
                  );
                }

                final tab = tabs[i];
                final isSelected = tab.id == activeTabId;
                final effectiveSerial = tab.deviceSerial ?? activeDeviceSerial;
                final deviceLabel = _deviceShortLabel(effectiveSerial);

                return _LogTabChip(
                  tab: tab,
                  isSelected: isSelected,
                  canClose: canClose,
                  isLastTab: i == tabs.length - 1,
                  deviceLabel: deviceLabel,
                  palette: palette,
                  onTap: () => onSelectTab(tab.id),
                  onClose: () => onCloseTab(tab.id),
                  onRename: () => _promptRename(context, tab, palette),
                  onDuplicate: () => onDuplicateTab(tab.id),
                  onCloseOthers: () => onCloseOtherTabs(tab.id),
                  onCloseToRight: () => onCloseTabsToRight(tab.id),
                  onClearDeviceBuffer: onClearDeviceBuffer,
                );
              },
            ),
          ),

          if (showGridButton) ...[
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
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _LogTabChip extends StatefulWidget {
  const _LogTabChip({
    required this.tab,
    required this.isSelected,
    required this.canClose,
    required this.isLastTab,
    required this.deviceLabel,
    required this.palette,
    required this.onTap,
    required this.onClose,
    required this.onRename,
    required this.onDuplicate,
    required this.onCloseOthers,
    required this.onCloseToRight,
    this.onClearDeviceBuffer,
  });

  final LogTabState tab;
  final bool isSelected;
  final bool canClose;
  final bool isLastTab;
  final String? deviceLabel;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onCloseOthers;
  final VoidCallback onCloseToRight;
  final VoidCallback? onClearDeviceBuffer;

  @override
  State<_LogTabChip> createState() => _LogTabChipState();
}

class _LogTabChipState extends State<_LogTabChip> {
  bool _hovered = false;
  DateTime? _lastTapAt;

  void _handleTap() {
    widget.onTap();
    final now = DateTime.now();
    if (_lastTapAt != null &&
        now.difference(_lastTapAt!) < const Duration(milliseconds: 350)) {
      _lastTapAt = null;
      widget.onRename();
    } else {
      _lastTapAt = now;
    }
  }

  Future<void> _showContextMenu(Offset globalPosition) async {
    final palette = widget.palette;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      color: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: palette.border),
      ),
      items: [
        PopupMenuItem(
          value: 'rename',
          child: Text('Rename Tab', style: TextStyle(fontSize: 12, color: palette.text)),
        ),
        PopupMenuItem(
          value: 'duplicate',
          child: Text('Duplicate Tab', style: TextStyle(fontSize: 12, color: palette.text)),
        ),
        if (widget.onClearDeviceBuffer != null)
          PopupMenuItem(
            value: 'clear_device',
            child: Text(
              'Clear Device Buffer (adb logcat -c)',
              style: TextStyle(fontSize: 12, color: palette.text),
            ),
          ),
        if (widget.canClose) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'close',
            child: Text('Close Tab', style: TextStyle(fontSize: 12, color: palette.text)),
          ),
          PopupMenuItem(
            value: 'close_others',
            child: Text('Close Other Tabs', style: TextStyle(fontSize: 12, color: palette.text)),
          ),
          if (!widget.isLastTab)
            PopupMenuItem(
              value: 'close_right',
              child: Text(
                'Close Tabs to the Right',
                style: TextStyle(fontSize: 12, color: palette.text),
              ),
            ),
        ],
      ],
    );

    switch (selected) {
      case 'rename':
        widget.onRename();
      case 'duplicate':
        widget.onDuplicate();
      case 'clear_device':
        widget.onClearDeviceBuffer?.call();
      case 'close':
        widget.onClose();
      case 'close_others':
        widget.onCloseOthers();
      case 'close_right':
        widget.onCloseToRight();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final tab = widget.tab;
    final showClose = widget.canClose && (widget.isSelected || _hovered);
    final levelCol = palette.levelColor[tab.minLevel];

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (event) {
          if (widget.canClose &&
              (event.buttons & kMiddleMouseButton) != 0) {
            widget.onClose();
          }
        },
        child: InkWell(
          onTap: _handleTap,
          onSecondaryTapDown: (d) => _showContextMenu(d.globalPosition),
          borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color:
                    widget.isSelected
                        ? palette.bg
                        : (_hovered
                            ? palette.bg.withValues(alpha: 0.45)
                            : Colors.transparent),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color:
                      widget.isSelected ? palette.accent : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    tab.paused ? Icons.pause_circle_filled : Icons.article_outlined,
                    size: 13,
                    color:
                        tab.paused
                            ? (palette.levelColor['W'] ?? Colors.orange)
                            : (widget.isSelected ? palette.accent : palette.dim),
                  ),
                  const SizedBox(width: 5),
                  if (widget.deviceLabel != null) ...[
                    Text(
                      '${widget.deviceLabel} · ',
                      style: TextStyle(
                        fontSize: 10,
                        color: palette.dim,
                      ),
                    ),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      tab.displayTitle,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            widget.isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                        color: widget.isSelected ? palette.text : palette.dim,
                      ),
                    ),
                  ),
                  if (tab.minLevel != 'V') ...[
                    const SizedBox(width: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: (levelCol ?? palette.dim).withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '${tab.minLevel}+',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: levelCol ?? palette.dim,
                        ),
                      ),
                    ),
                  ],
                  if (widget.canClose) ...[
                    const SizedBox(width: 4),
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 100),
                      opacity: showClose ? 1.0 : 0.0,
                      child: InkWell(
                        onTap: showClose ? widget.onClose : null,
                        borderRadius: BorderRadius.circular(3),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.close,
                            size: 12,
                            color: palette.dim,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
  }
}
