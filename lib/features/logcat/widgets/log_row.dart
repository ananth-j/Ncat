import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../src/column_config.dart';
import '../../../src/palette.dart';
import '../models/log_entry.dart';

/// Single log entry row in the log table.
class LogRow extends StatefulWidget {
  const LogRow({
    super.key,
    required this.entry,
    required this.columns,
    required this.wrap,
    required this.onCopy,
    required this.onFilterTag,
    required this.onFilterPackage,
    this.appPid,
    this.packageFilter,
  });

  final LogEntry entry;
  final LogColumnConfig columns;
  final bool wrap;
  final VoidCallback onCopy;
  final VoidCallback onFilterTag;
  final ValueChanged<String> onFilterPackage;
  final int? appPid;
  final String? packageFilter;

  @override
  State<LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<LogRow> {
  bool _hovered = false;

  void _showContextMenu(TapDownDetails details) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final palette = context.palette;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(details.globalPosition.dx, details.globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );

    showMenu<void>(
      context: context,
      position: position,
      color: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: palette.border),
      ),
      items: [
        PopupMenuItem<void>(
          onTap: widget.onCopy,
          child: Row(
            children: [
              Icon(Icons.copy, size: 14, color: palette.dim),
              const SizedBox(width: 8),
              Text(
                'Copy full line',
                style: TextStyle(fontSize: 12, color: palette.text),
              ),
            ],
          ),
        ),
        PopupMenuItem<void>(
          onTap: () => Clipboard.setData(ClipboardData(text: widget.entry.msg)),
          child: Row(
            children: [
              Icon(Icons.wrap_text, size: 14, color: palette.dim),
              const SizedBox(width: 8),
              Text(
                'Copy message only',
                style: TextStyle(fontSize: 12, color: palette.text),
              ),
            ],
          ),
        ),
        PopupMenuItem<void>(
          onTap: () => Clipboard.setData(ClipboardData(text: widget.entry.tag)),
          child: Row(
            children: [
              Icon(Icons.bookmark_outline, size: 14, color: palette.dim),
              const SizedBox(width: 8),
              Text(
                'Copy tag',
                style: TextStyle(fontSize: 12, color: palette.text),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<void>(
          onTap: widget.onFilterTag,
          child: Row(
            children: [
              Icon(Icons.search, size: 14, color: palette.dim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Filter by tag: "${widget.entry.tag}"',
                  style: TextStyle(fontSize: 12, color: palette.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        if (widget.entry.pkg != null && widget.entry.pkg!.isNotEmpty)
          PopupMenuItem<void>(
            onTap: () => widget.onFilterPackage(widget.entry.pkg!),
            child: Row(
              children: [
                Icon(Icons.phone_android, size: 14, color: palette.dim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Filter by package: "${widget.entry.pkg}"',
                    style: TextStyle(fontSize: 12, color: palette.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final level = widget.entry.level;
    final levelColor = palette.levelColor[level] ?? palette.dim;

    final msgColor = switch (level) {
      'E' || 'F' => levelColor,
      'W' => levelColor,
      _ => palette.text,
    };

    const mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 11.5,
      height: 1.4,
    );

    final appPkg =
        widget.entry.pkg ??
        (widget.appPid != null && widget.entry.pid == widget.appPid
            ? (widget.packageFilter != null && widget.packageFilter!.isNotEmpty
                ? widget.packageFilter!
                : 'app')
            : (widget.entry.pid == 0 ? 'system' : '-'));

    return GestureDetector(
      onSecondaryTapDown: _showContextMenu,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          color:
              _hovered
                  ? palette.selectedBg.withValues(alpha: 0.4)
                  : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Time
              if (widget.columns.showTime) ...[
                SizedBox(
                  width: 110,
                  child: Text(
                    widget.entry.time,
                    style: mono.copyWith(
                      color: palette.dim.withValues(alpha: 0.85),
                    ),
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              // PID-TID
              if (widget.columns.showPidTid) ...[
                SizedBox(
                  width: 82,
                  child: Text(
                    '${widget.entry.pid}-${widget.entry.tid}',
                    style: mono.copyWith(
                      color: palette.dim.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              // App Package Name
              if (widget.columns.showPackage) ...[
                SizedBox(
                  width: 140,
                  child: Tooltip(
                    message: appPkg,
                    child: Text(
                      appPkg,
                      style: mono.copyWith(
                        color: palette.dim.withValues(alpha: 0.85),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // Level Badge
              if (widget.columns.showLevel) ...[
                Container(
                  width: 26,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 0.5),
                  decoration: BoxDecoration(
                    color: levelColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: levelColor.withValues(alpha: 0.3),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    level,
                    style: mono.copyWith(
                      color: levelColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 10.5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // Tag
              if (widget.columns.showTag) ...[
                SizedBox(
                  width: 140,
                  child: Text(
                    widget.entry.tag,
                    style: mono.copyWith(
                      color: levelColor,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // Message
              Expanded(
                child: Text(
                  widget.entry.msg,
                  style: mono.copyWith(color: msgColor, fontSize: 13.5),
                  softWrap: widget.wrap,
                  maxLines: widget.wrap ? null : 1,
                  overflow: widget.wrap ? null : TextOverflow.ellipsis,
                ),
              ),
              // Copy button on hover
              Opacity(
                opacity: _hovered ? 1.0 : 0.0,
                child: Tooltip(
                  message: 'Copy line',
                  child: IconButton(
                    icon: Icon(Icons.copy, size: 12, color: palette.dim),
                    onPressed: widget.onCopy,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
