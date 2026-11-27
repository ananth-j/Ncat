import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../../devices/device_controller.dart';
import '../../devices/models/device_info.dart';
import '../logcat_controller.dart' show LogSplitAxis;
import '../models/log_tab_state.dart';

/// Android Studio Logcat-style horizontal tab bar supporting draggable tab
/// reordering, split-view controls, and multi-tab per-device workflows.
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
    this.secondaryTabId,
    this.splitAxis = LogSplitAxis.none,
    this.onReorderTab,
    this.onSplitWithTab,
    this.onToggleSplit,
    this.onCloseSplit,
    this.onClearDeviceBuffer,
  });

  final List<LogTabState> tabs;
  final String activeTabId;
  final String? secondaryTabId;
  final LogSplitAxis splitAxis;
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
  final void Function(String draggedTabId, int targetIndex)? onReorderTab;
  final void Function(String tabId, LogSplitAxis axis)? onSplitWithTab;
  final ValueChanged<LogSplitAxis>? onToggleSplit;
  final VoidCallback? onCloseSplit;
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
    final isSplit = splitAxis != LogSplitAxis.none;
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
                  return DragTarget<String>(
                    onWillAcceptWithDetails:
                        (details) => onReorderTab != null && details.data.isNotEmpty,
                    onAcceptWithDetails:
                        (details) => onReorderTab?.call(details.data, tabs.length),
                    builder: (context, candidateData, _) {
                      final isOver = candidateData.isNotEmpty;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isOver)
                            Container(
                              width: 2,
                              height: 20,
                              margin: const EdgeInsets.only(right: 4),
                              color: palette.accent,
                            ),
                          Tooltip(
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
                                child: Icon(
                                  Icons.add,
                                  size: 16,
                                  color: palette.dim,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                }

                final tab = tabs[i];
                final isSelected = tab.id == activeTabId;
                final isVisibleInOtherPane =
                    isSplit && tab.id == secondaryTabId && !isSelected;
                final effectiveSerial = tab.deviceSerial ?? activeDeviceSerial;
                final deviceLabel = _deviceShortLabel(effectiveSerial);

                return _DraggableLogTabSlot(
                  index: i,
                  tab: tab,
                  isSelected: isSelected,
                  isVisibleInOtherPane: isVisibleInOtherPane,
                  canClose: canClose,
                  isLastTab: i == tabs.length - 1,
                  isSplit: isSplit,
                  deviceLabel: deviceLabel,
                  palette: palette,
                  onTap: () => onSelectTab(tab.id),
                  onClose: () => onCloseTab(tab.id),
                  onRename: () => _promptRename(context, tab, palette),
                  onDuplicate: () => onDuplicateTab(tab.id),
                  onCloseOthers: () => onCloseOtherTabs(tab.id),
                  onCloseToRight: () => onCloseTabsToRight(tab.id),
                  onSplitRight:
                      onSplitWithTab != null
                          ? () => onSplitWithTab!(tab.id, LogSplitAxis.horizontal)
                          : null,
                  onSplitDown:
                      onSplitWithTab != null
                          ? () => onSplitWithTab!(tab.id, LogSplitAxis.vertical)
                          : null,
                  onCloseSplit: onCloseSplit,
                  onClearDeviceBuffer: onClearDeviceBuffer,
                  onReorderAccept:
                      onReorderTab != null
                          ? (draggedId) => onReorderTab!(draggedId, i)
                          : null,
                );
              },
            ),
          ),

          if (onToggleSplit != null) ...[
            Tooltip(
              message:
                  splitAxis == LogSplitAxis.horizontal
                      ? 'Close Side-by-Side Split (Ctrl+\\)'
                      : 'Split Right: View 2 Tabs Side-by-Side (Ctrl+\\)',
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: Icon(
                  Icons.vertical_split_outlined,
                  size: 15,
                  color:
                      splitAxis == LogSplitAxis.horizontal
                          ? palette.accent
                          : palette.dim,
                ),
                onPressed: () => onToggleSplit!(LogSplitAxis.horizontal),
              ),
            ),
            Tooltip(
              message:
                  splitAxis == LogSplitAxis.vertical
                      ? 'Close Top/Bottom Split'
                      : 'Split Down: View 2 Tabs Stacked',
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: Icon(
                  Icons.horizontal_split_outlined,
                  size: 15,
                  color:
                      splitAxis == LogSplitAxis.vertical
                          ? palette.accent
                          : palette.dim,
                ),
                onPressed: () => onToggleSplit!(LogSplitAxis.vertical),
              ),
            ),
          ],

          if (showGridButton) ...[
            Tooltip(
              message:
                  viewMode == DeviceViewMode.grid
                      ? 'Switch to Tabs view'
                      : 'Switch to Multi-Device Matrix Grid (2-4 devices)',
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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
          ],
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _DraggableLogTabSlot extends StatelessWidget {
  const _DraggableLogTabSlot({
    required this.index,
    required this.tab,
    required this.isSelected,
    required this.isVisibleInOtherPane,
    required this.canClose,
    required this.isLastTab,
    required this.isSplit,
    required this.deviceLabel,
    required this.palette,
    required this.onTap,
    required this.onClose,
    required this.onRename,
    required this.onDuplicate,
    required this.onCloseOthers,
    required this.onCloseToRight,
    this.onSplitRight,
    this.onSplitDown,
    this.onCloseSplit,
    this.onClearDeviceBuffer,
    this.onReorderAccept,
  });

  final int index;
  final LogTabState tab;
  final bool isSelected;
  final bool isVisibleInOtherPane;
  final bool canClose;
  final bool isLastTab;
  final bool isSplit;
  final String? deviceLabel;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onCloseOthers;
  final VoidCallback onCloseToRight;
  final VoidCallback? onSplitRight;
  final VoidCallback? onSplitDown;
  final VoidCallback? onCloseSplit;
  final VoidCallback? onClearDeviceBuffer;
  final ValueChanged<String>? onReorderAccept;

  @override
  Widget build(BuildContext context) {
    final chip = _LogTabChip(
      tab: tab,
      isSelected: isSelected,
      isVisibleInOtherPane: isVisibleInOtherPane,
      canClose: canClose,
      isLastTab: isLastTab,
      isSplit: isSplit,
      deviceLabel: deviceLabel,
      palette: palette,
      onTap: onTap,
      onClose: onClose,
      onRename: onRename,
      onDuplicate: onDuplicate,
      onCloseOthers: onCloseOthers,
      onCloseToRight: onCloseToRight,
      onSplitRight: onSplitRight,
      onSplitDown: onSplitDown,
      onCloseSplit: onCloseSplit,
      onClearDeviceBuffer: onClearDeviceBuffer,
    );

    final draggable = Draggable<String>(
      data: tab.id,
      maxSimultaneousDrags: 1,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.88,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: palette.panel,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: palette.accent),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.article_outlined, size: 13, color: palette.accent),
                const SizedBox(width: 5),
                Text(
                  tab.displayTitle,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: chip),
      child: chip,
    );

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != tab.id,
      onAcceptWithDetails: (details) => onReorderAccept?.call(details.data),
      builder: (context, candidateData, _) {
        final isHovering = candidateData.isNotEmpty;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isHovering)
              Container(
                width: 2,
                height: 20,
                margin: const EdgeInsets.only(right: 3),
                color: palette.accent,
              ),
            draggable,
          ],
        );
      },
    );
  }
}

class _LogTabChip extends StatefulWidget {
  const _LogTabChip({
    required this.tab,
    required this.isSelected,
    required this.isVisibleInOtherPane,
    required this.canClose,
    required this.isLastTab,
    required this.isSplit,
    required this.deviceLabel,
    required this.palette,
    required this.onTap,
    required this.onClose,
    required this.onRename,
    required this.onDuplicate,
    required this.onCloseOthers,
    required this.onCloseToRight,
    this.onSplitRight,
    this.onSplitDown,
    this.onCloseSplit,
    this.onClearDeviceBuffer,
  });

  final LogTabState tab;
  final bool isSelected;
  final bool isVisibleInOtherPane;
  final bool canClose;
  final bool isLastTab;
  final bool isSplit;
  final String? deviceLabel;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onCloseOthers;
  final VoidCallback onCloseToRight;
  final VoidCallback? onSplitRight;
  final VoidCallback? onSplitDown;
  final VoidCallback? onCloseSplit;
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
        if (widget.onSplitRight != null)
          PopupMenuItem(
            value: 'split_right',
            child: Text(
              'Split Right (Side-by-Side)',
              style: TextStyle(fontSize: 12, color: palette.text),
            ),
          ),
        if (widget.onSplitDown != null)
          PopupMenuItem(
            value: 'split_down',
            child: Text(
              'Split Down (Top / Bottom)',
              style: TextStyle(fontSize: 12, color: palette.text),
            ),
          ),
        if (widget.isSplit && widget.onCloseSplit != null)
          PopupMenuItem(
            value: 'close_split',
            child: Text(
              'Close Split View',
              style: TextStyle(fontSize: 12, color: palette.text),
            ),
          ),
        if (widget.onSplitRight != null || widget.onSplitDown != null)
          const PopupMenuDivider(),
        PopupMenuItem(
          value: 'rename',
          child: Text(
            'Rename Tab',
            style: TextStyle(fontSize: 12, color: palette.text),
          ),
        ),
        PopupMenuItem(
          value: 'duplicate',
          child: Text(
            'Duplicate Tab',
            style: TextStyle(fontSize: 12, color: palette.text),
          ),
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
            child: Text(
              'Close Tab',
              style: TextStyle(fontSize: 12, color: palette.text),
            ),
          ),
          PopupMenuItem(
            value: 'close_others',
            child: Text(
              'Close Other Tabs',
              style: TextStyle(fontSize: 12, color: palette.text),
            ),
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
      case 'split_right':
        widget.onSplitRight?.call();
      case 'split_down':
        widget.onSplitDown?.call();
      case 'close_split':
        widget.onCloseSplit?.call();
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

    final Color borderColor =
        widget.isSelected
            ? palette.accent
            : (widget.isVisibleInOtherPane
                ? palette.accent.withValues(alpha: 0.45)
                : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (event) {
          if (widget.canClose && (event.buttons & kMiddleMouseButton) != 0) {
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
                      : (widget.isVisibleInOtherPane || _hovered
                          ? palette.bg.withValues(alpha: 0.45)
                          : Colors.transparent),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  tab.paused
                      ? Icons.pause_circle_filled
                      : Icons.article_outlined,
                  size: 13,
                  color:
                      tab.paused
                          ? (palette.levelColor['W'] ?? Colors.orange)
                          : (widget.isSelected || widget.isVisibleInOtherPane
                              ? palette.accent
                              : palette.dim),
                ),
                const SizedBox(width: 5),
                if (widget.deviceLabel != null) ...[
                  Text(
                    '${widget.deviceLabel} · ',
                    style: TextStyle(fontSize: 10, color: palette.dim),
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
                          widget.isSelected || widget.isVisibleInOtherPane
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          widget.isSelected || widget.isVisibleInOtherPane
                              ? palette.text
                              : palette.dim,
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
                        child: Icon(Icons.close, size: 12, color: palette.dim),
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
