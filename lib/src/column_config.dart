import 'package:shared_preferences/shared_preferences.dart';

/// Configuration for which log columns are visible in the logcat table.
class LogColumnConfig {
  const LogColumnConfig({
    this.showTime = true,
    this.showPidTid = true,
    this.showLevel = true,
    this.showTag = true,
    this.showPackage = true,
  });

  final bool showTime;
  final bool showPidTid;
  final bool showLevel;
  final bool showTag;
  final bool showPackage;

  LogColumnConfig copyWith({
    bool? showTime,
    bool? showPidTid,
    bool? showLevel,
    bool? showTag,
    bool? showPackage,
  }) {
    return LogColumnConfig(
      showTime: showTime ?? this.showTime,
      showPidTid: showPidTid ?? this.showPidTid,
      showLevel: showLevel ?? this.showLevel,
      showTag: showTag ?? this.showTag,
      showPackage: showPackage ?? this.showPackage,
    );
  }

  /// Preset: Standard view showing all metadata columns
  static const standard = LogColumnConfig(
    showTime: true,
    showPidTid: true,
    showLevel: true,
    showTag: true,
    showPackage: true,
  );

  /// Preset: Compact view showing time, level, and tag
  static const compact = LogColumnConfig(
    showTime: true,
    showPidTid: false,
    showLevel: true,
    showTag: true,
    showPackage: false,
  );

  /// Preset: Minimal view showing only tag and message
  static const minimal = LogColumnConfig(
    showTime: false,
    showPidTid: false,
    showLevel: false,
    showTag: true,
    showPackage: false,
  );

  /// Preset: Raw message text only (like a clean terminal/console stream)
  static const messageOnly = LogColumnConfig(
    showTime: false,
    showPidTid: false,
    showLevel: false,
    showTag: false,
    showPackage: false,
  );
}

const _kColTimeKey = 'wcat.col_time';
const _kColPidTidKey = 'wcat.col_pid_tid';
const _kColLevelKey = 'wcat.col_level';
const _kColTagKey = 'wcat.col_tag';
const _kColPackageKey = 'wcat.col_package';

Future<LogColumnConfig> loadColumnConfig() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return LogColumnConfig(
      showTime: prefs.getBool(_kColTimeKey) ?? true,
      showPidTid: prefs.getBool(_kColPidTidKey) ?? true,
      showLevel: prefs.getBool(_kColLevelKey) ?? true,
      showTag: prefs.getBool(_kColTagKey) ?? true,
      showPackage: prefs.getBool(_kColPackageKey) ?? true,
    );
  } catch (_) {
    return const LogColumnConfig();
  }
}

Future<void> saveColumnConfig(LogColumnConfig config) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kColTimeKey, config.showTime);
    await prefs.setBool(_kColPidTidKey, config.showPidTid);
    await prefs.setBool(_kColLevelKey, config.showLevel);
    await prefs.setBool(_kColTagKey, config.showTag);
    await prefs.setBool(_kColPackageKey, config.showPackage);
  } catch (_) {}
}
