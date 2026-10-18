import 'package:flutter/material.dart';

import '../../../src/column_config.dart';
import '../../../src/palette.dart';
import '../models/log_entry.dart';
import 'column_config_dialog.dart';
import 'log_row.dart';

/// Table view presenting logcat column headers and the scrollable list of log rows.
class LogTableView extends StatelessWidget {
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
  });

  final List<LogEntry> entries;
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
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Column(
      children: [
        _columnHeader(context, palette),
        Expanded(
          child: Stack(
            children: [
              _logList(context, palette),
              if (!autoScroll)
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
                      onPressed: onScrollToEnd,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.arrow_downward, size: 14),
                          SizedBox(width: 4),
                          Text('Scroll to end', style: TextStyle(fontSize: 11)),
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
  }

  Widget _columnHeader(BuildContext context, AppPalette palette) {
    const headerStyle = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );
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
              width: 110,
              child: Text(
                'TIME',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (columns.showPidTid) ...[
            SizedBox(
              width: 82,
              child: Text(
                'PID-TID',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (columns.showPackage) ...[
            SizedBox(
              width: 140,
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
              width: 140,
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
                  const SizedBox(width: 4),
                  Text(
                    'Columns',
                    style: TextStyle(fontSize: 11, color: palette.dim),
                  ),
                ],
              ),
            ),
            itemBuilder:
                (context) => buildColumnMenuItems(
                  palette: palette,
                  columns: columns,
                  onUpdateColumns: onUpdateColumns,
                ),
          ),
        ],
      ),
    );
  }

  Widget _logList(BuildContext context, AppPalette palette) {
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
            Text(
              totalLinesCount == 0
                  ? 'Waiting for log output...'
                  : 'Nothing matches the current filter.',
              style: TextStyle(color: palette.dim, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return SelectionArea(
      child: Scrollbar(
        controller: scrollController,
        thumbVisibility: true,
        interactive: true,
        child: ListView.builder(
          controller: scrollController,
          itemExtent: wrap ? null : 24.0,
          padding: const EdgeInsets.symmetric(vertical: 2),
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final e = entries[i];
            return LogRow(
              key: ValueKey(e.seq),
              entry: e,
              columns: columns,
              wrap: wrap,
              appPid: appPid,
              packageFilter: packageFilter,
              onCopy: () => onCopy(e),
              onFilterTag: () => onFilterTag(e.tag),
              onFilterPackage: onFilterPackage,
            );
          },
        ),
      ),
    );
  }
}
