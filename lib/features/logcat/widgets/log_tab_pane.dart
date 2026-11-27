import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../logcat_controller.dart';
import '../models/log_entry.dart';
import 'column_config_dialog.dart';
import 'log_tab_toolbar.dart';
import 'log_table_view.dart';
import 'presets_dialog.dart';
import 'top_filter_bar.dart';

/// Self-contained Android Studio Logcat-style tab pane.
///
/// Every log action (device selector, package/query filter, severity level,
/// noise reduction, clear, pause, scroll to end/top, wrap, columns, presets,
/// export, and restart) is scoped to this individual [tab].
class LogTabPane extends StatelessWidget {
  const LogTabPane({
    super.key,
    required this.controller,
    required this.tab,
    required this.paneIndex,
    required this.isSplit,
    required this.isFocused,
    required this.isSecondary,
    required this.onNotify,
    required this.onExportTab,
  });

  final LogcatController controller;
  final LogTabState tab;
  final int paneIndex;
  final bool isSplit;
  final bool isFocused;
  final bool isSecondary;
  final void Function(String message, {bool isError}) onNotify;
  final Future<void> Function(String tabId) onExportTab;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tabAppPid = controller.appPidForTab(tab);

    final content = Column(
      children: [
        if (isSplit)
          _SplitPaneHeader(
            tab: tab,
            tabs: controller.logTabs,
            isFocused: isFocused,
            isSecondary: isSecondary,
            palette: palette,
            onFocus: () => controller.focusPane(paneIndex),
            onSelectTabForPane: (tabId) {
              controller.focusPane(paneIndex);
              controller.selectTab(tabId);
            },
            onCloseSplit: controller.closeSplit,
          ),

        // Per-tab filter bar (device picker, package, noise, search, level)
        TopFilterBar(
          searchCtrl: tab.searchController,
          pkgCtrl: tab.pkgController,
          minLevel: tab.minLevel,
          useRegex: tab.useRegex,
          appPid: tabAppPid,
          devices: controller.devices,
          pickedDevice: tab.deviceSerial ?? controller.deviceController.pickedDevice,
          noiseMode: tab.noiseMode,
          onSearch:
              (v) => controller.setSearchForTab(tab.id, v, immediate: false),
          onLevel: (v) => controller.setMinLevelForTab(tab.id, v),
          onPackage: () => controller.applyPackageForTab(tab.id),
          onRegex: () => controller.toggleRegexForTab(tab.id),
          onDevice: (s) => controller.setTabDeviceForTab(tab.id, s),
          onNoiseMode: (m) => controller.setNoiseModeForTab(tab.id, m),
        ),

        // Per-tab log toolbar + log table view
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LogTabToolbar(
                paused: tab.paused,
                wrap: tab.wrap,
                atBottom: tab.autoScroll,
                onPause: () => controller.togglePausedForTab(tab.id),
                onWrap: () => controller.toggleWrapForTab(tab.id),
                onScrollToEnd: () => controller.scrollToEndForTab(tab.id),
                onScrollToTop: () => controller.scrollToTopForTab(tab.id),
                onClear: () => controller.clearLogsForTab(tab.id),
                onRestart: () => controller.restartAdbForTab(tab.id),
                onExport: () => onExportTab(tab.id),
                onPresets:
                    () => showPresetsDialog(
                      context: context,
                      presets: controller.presets,
                      onApplyPreset:
                          (p) => controller.applyPresetForTab(tab.id, p),
                      onSavePreset:
                          (name) => controller.savePresetForTab(tab.id, name),
                      onDeletePreset: controller.deletePreset,
                    ),
                onConfigureColumns:
                    () => showColumnConfigDialog(
                      context: context,
                      columns: controller.columns,
                      onUpdateColumns: controller.updateColumns,
                    ),
              ),
              Expanded(
                child: LogTableView(
                  entries: tab.visible,
                  entriesNotifier: tab.visibleNotifier,
                  statsNotifier: tab.statsNotifier,
                  totalLinesCount: tab.lines.length,
                  columns: controller.columns,
                  wrap: tab.wrap,
                  autoScroll: tab.autoScroll,
                  scrollController: tab.scrollController,
                  appPid: tabAppPid,
                  packageFilter: tab.pkgController.text.trim(),
                  onCopy: (entry) {
                    controller.copyLogEntry(entry, tab: tab);
                    onNotify('Log line copied to clipboard');
                  },
                  onFilterTag: (tag) {
                    controller.focusPane(paneIndex);
                    controller.setFilterTagForTab(tab.id, tag);
                  },
                  onFilterPackage: (pkg) {
                    controller.focusPane(paneIndex);
                    controller.setFilterPackageForTab(tab.id, pkg);
                  },
                  onScrollToEnd: () => controller.scrollToEndForTab(tab.id),
                  onUpdateColumns: controller.updateColumns,
                ),
              ),
            ],
          ),
        ),

        // Per-pane live stats strip when split so each pane shows its own state
        if (isSplit)
          ValueListenableBuilder<LogStats>(
            valueListenable: tab.statsNotifier,
            builder: (context, stats, _) {
              return Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: palette.statusBarBg,
                  border: Border(top: BorderSide(color: palette.border)),
                ),
                child: Row(
                  children: [
                    if (tab.paused) ...[
                      Text(
                        'PAUSED',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: palette.levelColor['W'],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (!tab.autoScroll) ...[
                      Text(
                        'SCROLL PAUSED',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: palette.accent,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    const Spacer(),
                    Text(
                      (tab.noiseMode == NoiseFilterMode.reduce &&
                              stats.hiddenNoise > 0)
                          ? '${stats.visible} of ${stats.total} lines (${stats.hiddenNoise} noise hidden)'
                          : '${stats.visible} of ${stats.total} lines',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: palette.statusBarText,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );

    if (!isSplit) {
      return content;
    }

    return Listener(
      onPointerDown: (_) => controller.focusPane(paneIndex),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color:
                isFocused
                    ? palette.accent.withValues(alpha: 0.7)
                    : palette.border,
          ),
        ),
        child: content,
      ),
    );
  }
}

class _SplitPaneHeader extends StatelessWidget {
  const _SplitPaneHeader({
    required this.tab,
    required this.tabs,
    required this.isFocused,
    required this.isSecondary,
    required this.palette,
    required this.onFocus,
    required this.onSelectTabForPane,
    required this.onCloseSplit,
  });

  final LogTabState tab;
  final List<LogTabState> tabs;
  final bool isFocused;
  final bool isSecondary;
  final AppPalette palette;
  final VoidCallback onFocus;
  final ValueChanged<String> onSelectTabForPane;
  final VoidCallback onCloseSplit;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onFocus,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: isFocused ? palette.accentBg : palette.panel,
          border: Border(bottom: BorderSide(color: palette.border)),
        ),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    isFocused
                        ? palette.accent
                        : palette.dim.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 6),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: tabs.any((t) => t.id == tab.id) ? tab.id : null,
                isDense: true,
                dropdownColor: palette.panel,
                icon: Icon(Icons.arrow_drop_down, size: 15, color: palette.dim),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isFocused ? FontWeight.w600 : FontWeight.normal,
                  color: palette.text,
                ),
                items: [
                  for (final t in tabs)
                    DropdownMenuItem<String>(
                      value: t.id,
                      child: Text(
                        t.displayTitle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) {
                  if (id != null) onSelectTabForPane(id);
                },
              ),
            ),
            const Spacer(),
            if (isSecondary)
              Tooltip(
                message: 'Close Split Pane',
                child: InkWell(
                  onTap: onCloseSplit,
                  borderRadius: BorderRadius.circular(3),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 13, color: palette.dim),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
