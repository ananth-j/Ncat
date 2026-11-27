import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../src/column_config.dart';
import '../../../src/palette.dart';
import '../models/log_entry.dart';
import 'column_config_dialog.dart';
import 'log_row.dart';

/// Table view presenting logcat column headers and the scrollable list of log rows.
///
/// ## Performance design
///
/// The widget accepts the [entries] list directly for cases like filter changes
/// where the full list changes at once, **and** accepts an optional
/// [entriesNotifier] so that the log list can rebuild independently of the
/// parent widget tree when only new rows arrive (incremental batch updates).
/// When [entriesNotifier] is non-null it takes precedence over [entries].
///
/// The hover [ValueNotifier] is kept in this [State] so only the two rows
/// whose hover-state changes get rebuilt — not the entire list.
///
/// Each [LogRow] is wrapped in a [RepaintBoundary] so that painting one row
/// does not propagate dirty regions to its neighbours.
class LogTableView extends StatefulWidget {
  const LogTableView({
    super.key,
    required this.entries,
    required this.totalLinesCount,
    required this.columns,
    required this.wrap,
    required this.autoScroll,
    required this.scrollController,
    required this.appPid,
    required this.packageFilter,
    required this.onCopy,
    required this.onFilterTag,
    required this.onFilterPackage,
    required this.onScrollToEnd,
    required this.onUpdateColumns,
    this.entriesNotifier,
    this.statsNotifier,
  });

  final List<LogEntry> entries;

  /// When supplied, the list view rebuilds from this notifier independently
  /// of the parent widget — entries arriving via the notifier do not cause the
  /// header, toolbar, or status bar to rebuild.
  final ValueNotifier<List<LogEntry>>? entriesNotifier;

  /// Optional line-count notifier used for the empty-state label so that
  /// transitioning from 0 to >0 total lines updates without rebuilding the page.
  final ValueListenable<LogStats>? statsNotifier;

  final int totalLinesCount;
  final LogColumnConfig columns;
  final bool wrap;
  final bool autoScroll;
  final ScrollController scrollController;
  final int? appPid;
  final String packageFilter;
  final ValueChanged<LogEntry> onCopy;
  final ValueChanged<String> onFilterTag;
  final ValueChanged<String> onFilterPackage;
  final VoidCallback onScrollToEnd;
  final ValueChanged<LogColumnConfig> onUpdateColumns;

  @override
  State<LogTableView> createState() => _LogTableViewState();
}

class _LogTableViewState extends State<LogTableView> {
  /// Tracks which row is currently hovered by its sequence number.
  ///
  /// Stored here — not in [LogRow] — so that only the two affected rows
  /// rebuild on enter/exit, while the rest of the list stays untouched.
  final ValueNotifier<int?> _hoveredSeq = ValueNotifier<int?>(null);

  @override
  void dispose() {
    _hoveredSeq.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        final minTableWidth = compact ? 480.0 : 0.0;
        final table = Column(
          children: [
            _columnHeader(context, palette, compact: compact),
            Expanded(
              child: Stack(
                children: [
                  _logListOuter(context, palette, compact: compact),
                  if (!widget.autoScroll)
                    Positioned(
                      right: 18,
                      bottom: 18,
                      child: Tooltip(
                        message: 'Scroll to end',
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: palette.accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          onPressed: widget.onScrollToEnd,
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.arrow_downward, size: 14),
                              SizedBox(width: 4),
                              Text(
                                'Scroll to end',
                                style: TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );

        if (constraints.maxWidth < minTableWidth) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: minTableWidth,
              height: constraints.maxHeight,
              child: table,
            ),
          );
        }
        return table;
      },
    );
  }

  Widget _columnHeader(
    BuildContext context,
    AppPalette palette, {
    bool compact = false,
  }) {
    const headerStyle = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );
    final columns = widget.columns;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          if (columns.showTime) ...[
            SizedBox(
              width: compact ? 96 : 110,
              child: Text(
                'TIME',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (columns.showPidTid) ...[
            SizedBox(
              width: compact ? 68 : 82,
              child: Text(
                'PID-TID',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (columns.showPackage) ...[
            SizedBox(
              width: compact ? 88 : 140,
              child: Text(
                'PACKAGE',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (columns.showLevel) ...[
            SizedBox(
              width: 26,
              child: Text(
                'LVL',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (columns.showTag) ...[
            SizedBox(
              width: compact ? 88 : 140,
              child: Text(
                'TAG',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              'MESSAGE',
              overflow: TextOverflow.ellipsis,
              style: headerStyle.copyWith(color: palette.dim),
            ),
          ),
          // Columns menu button
          PopupMenuButton<void>(
            tooltip: 'Columns',
            color: palette.panel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
              side: BorderSide(color: palette.border),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.view_column_outlined,
                    size: 14,
                    color: palette.dim,
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 4),
                    Text(
                      'Columns',
                      style: TextStyle(fontSize: 11, color: palette.dim),
                    ),
                  ],
                ],
              ),
            ),
            itemBuilder:
                (context) => buildColumnMenuItems(
                  palette: palette,
                  columns: columns,
                  onUpdateColumns: widget.onUpdateColumns,
                ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // List area
  // ---------------------------------------------------------------------------

  /// Outer shell: decides whether to use [entriesNotifier] or [entries].
  Widget _logListOuter(
    BuildContext context,
    AppPalette palette, {
    bool compact = false,
  }) {
    final notifier = widget.entriesNotifier;
    if (notifier != null) {
      // Fast path: only the list rebuilds when new batches arrive.
      return ValueListenableBuilder<List<LogEntry>>(
        valueListenable: notifier,
        builder:
            (context, entries, _) =>
                _logListInner(context, palette, entries, compact: compact),
      );
    }
    return _logListInner(context, palette, widget.entries, compact: compact);
  }

  Widget _logListInner(
    BuildContext context,
    AppPalette palette,
    List<LogEntry> entries, {
    bool compact = false,
  }) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.phone_android,
              size: 36,
              color: palette.dim.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 10),
            if (widget.statsNotifier != null)
              ValueListenableBuilder<LogStats>(
                valueListenable: widget.statsNotifier!,
                builder:
                    (context, stats, _) => Text(
                      stats.total == 0
                          ? 'Waiting for log output...'
                          : 'Nothing matches the current filter.',
                      style: TextStyle(color: palette.dim, fontSize: 13),
                    ),
              )
            else
              Text(
                widget.totalLinesCount == 0
                    ? 'Waiting for log output...'
                    : 'Nothing matches the current filter.',
                style: TextStyle(color: palette.dim, fontSize: 13),
              ),
          ],
        ),
      );
    }

    // ---------------------------------------------------------------------------
    // SelectionArea is intentionally placed around only the Scrollbar+ListView,
    // NOT around the full widget. Placing it higher in the tree (e.g. at page
    // level) causes it to intercept pointer events for every widget it wraps,
    // which adds measurable overhead on every scroll event.
    // ---------------------------------------------------------------------------
    return SelectionArea(
      child: Scrollbar(
        controller: widget.scrollController,
        thumbVisibility: true,
        interactive: true,
        child: _HoverIsolatedList(
          hoveredSeq: _hoveredSeq,
          entries: entries,
          scrollController: widget.scrollController,
          wrap: widget.wrap,
          compact: compact,
          columns: widget.columns,
          appPid: widget.appPid,
          packageFilter: widget.packageFilter,
          onHover: (seq) => _hoveredSeq.value = seq,
          onCopy: widget.onCopy,
          onFilterTag: widget.onFilterTag,
          onFilterPackage: widget.onFilterPackage,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Isolated hover + list widget
// ---------------------------------------------------------------------------

/// Owns the [ValueListenableBuilder] for hover state so that moving the mouse
/// over a row only rebuilds this subtree — the [LogTableView] header, the
/// "scroll to end" button, and all ancestor widgets stay completely untouched.
///
/// Each row is additionally wrapped in a [RepaintBoundary] so that painting
/// one highlighted row does not mark its neighbours dirty.
class _HoverIsolatedList extends StatelessWidget {
  const _HoverIsolatedList({
    required this.hoveredSeq,
    required this.entries,
    required this.scrollController,
    required this.wrap,
    required this.compact,
    required this.columns,
    required this.appPid,
    required this.packageFilter,
    required this.onHover,
    required this.onCopy,
    required this.onFilterTag,
    required this.onFilterPackage,
  });

  final ValueNotifier<int?> hoveredSeq;
  final List<LogEntry> entries;
  final ScrollController scrollController;
  final bool wrap;
  final bool compact;
  final LogColumnConfig columns;
  final int? appPid;
  final String packageFilter;
  final ValueChanged<int?> onHover;
  final ValueChanged<LogEntry> onCopy;
  final ValueChanged<String> onFilterTag;
  final ValueChanged<String> onFilterPackage;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: hoveredSeq,
      builder: (context, hovered, _) {
        return ListView.builder(
          controller: scrollController,
          // Fixed row height lets Flutter skip layout entirely for off-screen
          // items. Must stay in sync with LogcatController._rowExtent.
          itemExtent: wrap ? null : 23.0,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true, // Flutter adds RepaintBoundary per item
          padding: EdgeInsets.zero,
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final e = entries[i];
            return LogRow(
              key: ValueKey(e.seq),
              entry: e,
              columns: columns,
              wrap: wrap,
              compact: compact,
              appPid: appPid,
              packageFilter: packageFilter,
              hoveredSeq: hovered,
              onHover: onHover,
              onCopy: onCopy,
              onFilterTag: onFilterTag,
              onFilterPackage: onFilterPackage,
            );
          },
        );
      },
    );
  }
}
