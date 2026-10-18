import 'package:flutter/material.dart';

import '../../../src/filter_preset.dart';
import '../../../src/palette.dart';

/// Opens the filter presets management dialog.
Future<void> showPresetsDialog({
  required BuildContext context,
  required List<FilterPreset> presets,
  required ValueChanged<FilterPreset> onApplyPreset,
  required Future<void> Function(String name) onSavePreset,
  required Future<void> Function(FilterPreset preset) onDeletePreset,
}) async {
  final palette = context.palette;
  final nameCtrl = TextEditingController();

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return Dialog(
            backgroundColor: palette.panel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: palette.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.bookmark_outline,
                          size: 18,
                          color: palette.accent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Filter Presets',
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
                      'Save current filter settings for quick access later.',
                      style: TextStyle(fontSize: 12, color: palette.dim),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 34,
                            child: TextField(
                              controller: nameCtrl,
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.text,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Preset name',
                                hintStyle: TextStyle(
                                  fontSize: 12,
                                  color: palette.dim,
                                ),
                                filled: true,
                                fillColor: palette.bg,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
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
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: palette.accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                          ),
                          onPressed: () async {
                            final name = nameCtrl.text.trim();
                            if (name.isEmpty) return;
                            await onSavePreset(name);
                            nameCtrl.clear();
                            setDialogState(() {});
                          },
                          child: const Text(
                            'Save current',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (presets.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        alignment: Alignment.center,
                        child: Text(
                          'No saved presets yet.',
                          style: TextStyle(fontSize: 12, color: palette.dim),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: presets.length,
                          separatorBuilder:
                              (_, __) =>
                                  Divider(height: 1, color: palette.border),
                          itemBuilder: (context, i) {
                            final p = presets[i];
                            final details = [
                              if (p.package.isNotEmpty) 'pkg: ${p.package}',
                              'level: ${p.minLevel}+',
                              if (p.search.isNotEmpty)
                                '${p.useRegex ? 're' : 'search'}: ${p.search}',
                            ].join('  ·  ');
                            return Material(
                              color: Colors.transparent,
                              child: InkWell(
                                hoverColor: palette.selectedBg.withValues(
                                  alpha: 0.5,
                                ),
                                borderRadius: BorderRadius.circular(4),
                                onTap: () {
                                  onApplyPreset(p);
                                  Navigator.of(dialogContext).pop();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                    horizontal: 8,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              p.name,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w600,
                                                color: palette.text,
                                              ),
                                            ),
                                            Text(
                                              details,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: palette.dim,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          Icons.delete_outline,
                                          size: 15,
                                          color: palette.dim,
                                        ),
                                        onPressed: () async {
                                          await onDeletePreset(p);
                                          setDialogState(() {});
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: palette.text,
                          ),
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('Close'),
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
  nameCtrl.dispose();
}
