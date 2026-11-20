import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../src/column_config.dart';
import '../../../src/palette.dart';
import '../models/log_entry.dart';

/// Base monospace style shared by every log cell.
const _monoStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 11.5,
  height: 1.25,
);

// ---------------------------------------------------------------------------
// Per-palette style cache
// ---------------------------------------------------------------------------

/// Pre-computed [TextStyle]s and [Color]s derived from an [AppPalette].
///
/// Computed once per palette instance and reused across all [LogRow] builds,
/// eliminating repeated [TextStyle.copyWith] / [Color.withValues] allocations
/// that would otherwise fire on every row rebuild.
class _LogRowStyles {
  _LogRowStyles._(this.palette)
    : dimStyle85 = _monoStyle.copyWith(
        color: palette.dim.withValues(alpha: 0.85),
      ),
      dimStyle70 = _monoStyle.copyWith(
        color: palette.dim.withValues(alpha: 0.7),
      ),
      hoveredBg = palette.selectedBg.withValues(alpha: 0.4);

  final AppPalette palette;
  final TextStyle dimStyle85;
  final TextStyle dimStyle70;
  final Color hoveredBg;

  /// Returns level-specific styles, cached by level letter.
  _LevelStyles levelStyles(String level) {
    return _levelCache.putIfAbsent(level, () {
      final color = palette.levelColor[level] ?? palette.dim;
      return _LevelStyles(
        color: color,
        badgeStyle: _monoStyle.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 10.5,
        ),
        tagStyle: _monoStyle.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
        msgStyle: _monoStyle.copyWith(
          color:
              (level == 'E' || level == 'F' || level == 'W')
                  ? color
                  : palette.text,
          fontSize: 12.5,
        ),
        badgeBg: color.withValues(alpha: 0.15),
        badgeBorder: color.withValues(alpha: 0.3),
      );
    });
  }

  final _levelCache = <String, _LevelStyles>{};
}

class _LevelStyles {
  const _LevelStyles({
    required this.color,
    required this.badgeStyle,
    required this.tagStyle,
    required this.msgStyle,
    required this.badgeBg,
    required this.badgeBorder,
  });

  final Color color;
  final TextStyle badgeStyle;
  final TextStyle tagStyle;
  final TextStyle msgStyle;
  final Color badgeBg;
  final Color badgeBorder;
}

/// Cache keyed by palette identity — survives across builds as long as the
/// palette object reference doesn't change (which it won't between theme switches).
final _stylesCache = Expando<_LogRowStyles>();

_LogRowStyles _stylesFor(AppPalette palette) =>
    _stylesCache[palette] ??= _LogRowStyles._(palette);

// ---------------------------------------------------------------------------
// LogRow widget
// ---------------------------------------------------------------------------

/// Single log entry row in the log table.
///
/// Stateless – hover state is lifted to the parent [LogTableView] via
/// [hoveredSeq] / [onHover] so that a hover change only rebuilds the
/// affected rows through a [ValueListenableBuilder], not the entire list.
class LogRow extends StatelessWidget {
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
    this.hoveredSeq,
    this.onHover,
  });

  final LogEntry entry;
  final LogColumnConfig columns;
  final bool wrap;
  final ValueChanged<LogEntry> onCopy;
  final ValueChanged<String> onFilterTag;
  final ValueChanged<String> onFilterPackage;
  final int? appPid;
  final String? packageFilter;

  /// The sequence number of the currently hovered row (or `null`).
  final int? hoveredSeq;

  /// Called with [entry.seq] on mouse-enter, `null` on mouse-exit.
  final ValueChanged<int?>? onHover;

  // ---------------------------------------------------------------------------
  // Context menu
  // ---------------------------------------------------------------------------

  static void showContextMenu(
    BuildContext context, {
    required TapDownDetails details,
    required LogEntry entry,
    required ValueChanged<LogEntry> onCopy,
    required ValueChanged<String> onFilterTag,
    required ValueChanged<String> onFilterPackage,
  }) {
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
          onTap: () => onCopy(entry),
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
          onTap: () => Clipboard.setData(ClipboardData(text: entry.msg)),
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
          onTap: () => Clipboard.setData(ClipboardData(text: entry.tag)),
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
          onTap: () => onFilterTag(entry.tag),
          child: Row(
            children: [
              Icon(Icons.search, size: 14, color: palette.dim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Filter by tag: "${entry.tag}"',
                  style: TextStyle(fontSize: 12, color: palette.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        if (entry.pkg != null && entry.pkg!.isNotEmpty)
          PopupMenuItem<void>(
            onTap: () => onFilterPackage(entry.pkg!),
            child: Row(
              children: [
                Icon(Icons.phone_android, size: 14, color: palette.dim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Filter by package: "${entry.pkg}"',
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

    // Pull pre-computed styles — zero allocations when palette hasn't changed.
    final styles = _stylesFor(palette);
    final ls = styles.levelStyles(entry.level);

    final hovered = hoveredSeq == entry.seq;

    final appPkg =
        entry.pkg ??
        (appPid != null && entry.pid == appPid
            ? (packageFilter != null && packageFilter!.isNotEmpty
                ? packageFilter!
                : 'app')
            : (entry.pid == 0 ? 'system' : '-'));

    return GestureDetector(
      onSecondaryTapDown:
          (details) => showContextMenu(
            context,
            details: details,
            entry: entry,
            onCopy: onCopy,
            onFilterTag: onFilterTag,
            onFilterPackage: onFilterPackage,
          ),
      child: MouseRegion(
        onEnter: (_) => onHover?.call(entry.seq),
        onExit: (_) => onHover?.call(null),
        // ColoredBox is cheaper than Container — it skips Container's layout
        // overhead and goes straight to painting.
        child: ColoredBox(
          color: hovered ? styles.hoveredBg : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Time
                if (columns.showTime) ...[
                  SizedBox(
                    width: 110,
                    child: Text(
                      entry.time,
                      style: styles.dimStyle85,
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                // PID-TID
                if (columns.showPidTid) ...[
                  SizedBox(
                    width: 82,
                    child: Text(
                      '${entry.pid}-${entry.tid}',
                      style: styles.dimStyle70,
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                // App Package Name
                if (columns.showPackage) ...[
                  SizedBox(
                    width: 140,
                    child: Tooltip(
                      message: appPkg,
                      child: Text(
                        appPkg,
                        style: styles.dimStyle85,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // Level Badge
                if (columns.showLevel) ...[
                  Container(
                    width: 26,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 0.5),
                    decoration: BoxDecoration(
                      // Pre-computed colors — no withValues() call here.
                      color: ls.badgeBg,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: ls.badgeBorder, width: 0.5),
                    ),
                    child: Text(entry.level, style: ls.badgeStyle),
                  ),
                  const SizedBox(width: 8),
                ],
                // Tag
                if (columns.showTag) ...[
                  SizedBox(
                    width: 140,
                    child: Text(
                      entry.tag,
                      style: ls.tagStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                // Message
                Expanded(
                  child: Text(
                    entry.msg,
                    style: ls.msgStyle,
                    softWrap: wrap,
                    maxLines: wrap ? null : 1,
                    overflow: wrap ? null : TextOverflow.ellipsis,
                  ),
                ),
                // Copy button — always in the tree to avoid mount/unmount cost;
                // hidden via Opacity so layout is stable. Only one row is ever
                // hovered at a time, so the Opacity paint cost is negligible.
                Opacity(
                  opacity: hovered ? 1.0 : 0.0,
                  child: Tooltip(
                    message: 'Copy line',
                    child: IconButton(
                      icon: Icon(Icons.copy, size: 12, color: palette.dim),
                      onPressed: () => onCopy(entry),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
