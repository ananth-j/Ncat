import 'package:flutter/material.dart';

import '../../../src/column_config.dart';
import '../../../src/palette.dart';

/// Opens the dialog to configure visible logcat table columns.
Future<void> showColumnConfigDialog({
  required BuildContext context,
  required LogColumnConfig columns,
  required ValueChanged<LogColumnConfig> onUpdateColumns,
}) async {
  final palette = context.palette;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Widget presetBtn(String label, LogColumnConfig config) {
            final active =
                columns.showTime == config.showTime &&
                columns.showPidTid == config.showPidTid &&
                columns.showPackage == config.showPackage &&
                columns.showLevel == config.showLevel &&
                columns.showTag == config.showTag;
            if (active) {
              return FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: palette.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                onPressed: () {},
                child: Text(label, style: const TextStyle(fontSize: 11)),
              );
            }
            return OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.text,
                side: BorderSide(color: palette.border),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              onPressed: () {
                onUpdateColumns(config);
                columns = config;
                setDialogState(() {});
              },
              child: Text(label, style: const TextStyle(fontSize: 11)),
            );
          }

          Widget columnCheckbox({
            required String title,
            required String subtitle,
            required bool value,
            required ValueChanged<bool?> onChanged,
          }) {
            return Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onChanged(!value),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        value: value,
                        activeColor: palette.accent,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: onChanged,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: palette.text,
                              ),
                            ),
                            Text(
                              subtitle,
                              style: TextStyle(
                                fontSize: 11,
                                color: palette.dim,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return Dialog(
            backgroundColor: palette.panel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: palette.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.view_column_outlined,
                          size: 18,
                          color: palette.accent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Configure Logcat Columns',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: palette.text,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: Icon(Icons.close, size: 16, color: palette.dim),
                          onPressed: () => Navigator.of(dialogContext).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Select fields to display in the log table. Unselected columns are removed, giving more space for messages.',
                      style: TextStyle(color: palette.dim, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        presetBtn('Standard (All)', LogColumnConfig.standard),
                        presetBtn('Compact', LogColumnConfig.compact),
                        presetBtn('Minimal', LogColumnConfig.minimal),
                        presetBtn('Message Only', LogColumnConfig.messageOnly),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Divider(height: 1, color: palette.border),
                    const SizedBox(height: 8),
                    columnCheckbox(
                      title: 'Timestamp (TIME)',
                      subtitle:
                          'Date and invocation time (e.g. 10-04 19:45:12.345)',
                      value: columns.showTime,
                      onChanged: (v) {
                        if (v != null) {
                          final updated = columns.copyWith(showTime: v);
                          onUpdateColumns(updated);
                          columns = updated;
                          setDialogState(() {});
                        }
                      },
                    ),
                    columnCheckbox(
                      title: 'Process / Thread (PID-TID)',
                      subtitle: 'Process and thread IDs (e.g. 1234-5678)',
                      value: columns.showPidTid,
                      onChanged: (v) {
                        if (v != null) {
                          final updated = columns.copyWith(showPidTid: v);
                          onUpdateColumns(updated);
                          columns = updated;
                          setDialogState(() {});
                        }
                      },
                    ),
                    columnCheckbox(
                      title: 'App Package Name (PACKAGE)',
                      subtitle:
                          'Application ID or process name (e.g. com.example.app)',
                      value: columns.showPackage,
                      onChanged: (v) {
                        if (v != null) {
                          final updated = columns.copyWith(showPackage: v);
                          onUpdateColumns(updated);
                          columns = updated;
                          setDialogState(() {});
                        }
                      },
                    ),
                    columnCheckbox(
                      title: 'Log Level (LVL)',
                      subtitle: 'Severity badge (V, D, I, W, E, F)',
                      value: columns.showLevel,
                      onChanged: (v) {
                        if (v != null) {
                          final updated = columns.copyWith(showLevel: v);
                          onUpdateColumns(updated);
                          columns = updated;
                          setDialogState(() {});
                        }
                      },
                    ),
                    columnCheckbox(
                      title: 'Tag (TAG)',
                      subtitle: 'Component tag (e.g. ActivityManager)',
                      value: columns.showTag,
                      onChanged: (v) {
                        if (v != null) {
                          final updated = columns.copyWith(showTag: v);
                          onUpdateColumns(updated);
                          columns = updated;
                          setDialogState(() {});
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: palette.accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// Builds popup menu items for quick column visibility toggling.
List<PopupMenuEntry<void>> buildColumnMenuItems({
  required AppPalette palette,
  required LogColumnConfig columns,
  required ValueChanged<LogColumnConfig> onUpdateColumns,
}) {
  return [
    CheckedPopupMenuItem<void>(
      checked: columns.showTime,
      value: null,
      onTap:
          () => onUpdateColumns(columns.copyWith(showTime: !columns.showTime)),
      child: Text(
        'Timestamp (TIME)',
        style: TextStyle(fontSize: 12, color: palette.text),
      ),
    ),
    CheckedPopupMenuItem<void>(
      checked: columns.showPidTid,
      value: null,
      onTap:
          () => onUpdateColumns(
            columns.copyWith(showPidTid: !columns.showPidTid),
          ),
      child: Text(
        'PID-TID',
        style: TextStyle(fontSize: 12, color: palette.text),
      ),
    ),
    CheckedPopupMenuItem<void>(
      checked: columns.showPackage,
      value: null,
      onTap:
          () => onUpdateColumns(
            columns.copyWith(showPackage: !columns.showPackage),
          ),
      child: Text(
        'Package Name',
        style: TextStyle(fontSize: 12, color: palette.text),
      ),
    ),
    CheckedPopupMenuItem<void>(
      checked: columns.showLevel,
      value: null,
      onTap:
          () =>
              onUpdateColumns(columns.copyWith(showLevel: !columns.showLevel)),
      child: Text(
        'Log Level (LVL)',
        style: TextStyle(fontSize: 12, color: palette.text),
      ),
    ),
    CheckedPopupMenuItem<void>(
      checked: columns.showTag,
      value: null,
      onTap: () => onUpdateColumns(columns.copyWith(showTag: !columns.showTag)),
      child: Text(
        'Tag (TAG)',
        style: TextStyle(fontSize: 12, color: palette.text),
      ),
    ),
    const PopupMenuDivider(),
    PopupMenuItem<void>(
      onTap: () => onUpdateColumns(LogColumnConfig.standard),
      child: Text(
        'Reset: Standard View (All)',
        style: TextStyle(fontSize: 12, color: palette.text),
      ),
    ),
    PopupMenuItem<void>(
      onTap: () => onUpdateColumns(LogColumnConfig.compact),
      child: Text(
        'Preset: Compact View',
        style: TextStyle(fontSize: 12, color: palette.text),
      ),
    ),
    PopupMenuItem<void>(
      onTap: () => onUpdateColumns(LogColumnConfig.messageOnly),
      child: Text(
        'Preset: Message Only',
        style: TextStyle(fontSize: 12, color: palette.text),
      ),
    ),
  ];
}
