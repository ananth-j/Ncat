import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'src/bridge_manager.dart';
import 'src/column_config.dart';
import 'src/export.dart';
import 'src/filter_preset.dart';
import 'src/palette.dart';
import 'src/theme_pref.dart';

void main() => runApp(const LogcatApp());

/// Newest entries are appended; the list is capped so a chatty device can't
/// grow memory without bound.
const int kMaxLines = 8000;

const List<String> _levels = ['V', 'D', 'I', 'W', 'E', 'F'];

const Map<String, String> _levelNames = {
  'V': 'Verbose',
  'D': 'Debug',
  'I': 'Info',
  'W': 'Warn',
  'E': 'Error',
  'F': 'Assert',
};

class LogEntry {
  const LogEntry({
    required this.seq,
    required this.time,
    required this.pid,
    required this.tid,
    required this.level,
    required this.tag,
    required this.msg,
    this.pkg,
  });

  final int seq;
  final String time;
  final int pid;
  final int tid;
  final String level;
  final String tag;
  final String msg;
  final String? pkg;

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
    seq: j['seq'] as int,
    time: j['time'] as String,
    pid: j['pid'] as int,
    tid: j['tid'] as int,
    level: j['level'] as String,
    tag: j['tag'] as String,
    msg: j['msg'] as String,
    pkg: j['pkg'] as String?,
  );

  int get rank => _levels.indexOf(level).clamp(0, _levels.length - 1);
}

class DeviceInfo {
  const DeviceInfo({required this.serial, this.model, this.authorized = true});

  final String serial;
  final String? model;
  final bool authorized;

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
    serial: j['serial'] as String,
    model: j['model'] as String?,
    authorized: j['authorized'] as bool? ?? true,
  );

  String get label {
    if (!authorized) return '$serial [Unauthorized]';
    return model == null ? serial : '$model ($serial)';
  }
}

class LogcatApp extends StatefulWidget {
  const LogcatApp({super.key});

  @override
  State<LogcatApp> createState() => _LogcatAppState();
}

class _LogcatAppState extends State<LogcatApp> {
  AppThemeChoice _themeChoice = AppThemeChoice.system;
  bool _userChangedTheme = false;

  @override
  void initState() {
    super.initState();
    loadThemeChoice().then((choice) {
      if (mounted && !_userChangedTheme) setState(() => _themeChoice = choice);
    });
  }

  void _setThemeChoice(AppThemeChoice choice) {
    _userChangedTheme = true;
    setState(() => _themeChoice = choice);
    saveThemeChoice(choice);
  }

  @override
  Widget build(BuildContext context) {
    final darkPalette =
        _themeChoice == AppThemeChoice.vsDark
            ? kVsDarkPalette
            : kDarkModernPalette;
    return MaterialApp(
      title: 'wcat',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light, kLightPalette),
      darkTheme: buildAppTheme(Brightness.dark, darkPalette),
      themeMode: switch (_themeChoice) {
        AppThemeChoice.system => ThemeMode.system,
        AppThemeChoice.light => ThemeMode.light,
        AppThemeChoice.darkModern || AppThemeChoice.vsDark => ThemeMode.dark,
      },
      home: LogcatPage(
        themeChoice: _themeChoice,
        onThemeChoice: _setThemeChoice,
      ),
    );
  }
}

class LogcatPage extends StatefulWidget {
  const LogcatPage({
    super.key,
    required this.themeChoice,
    required this.onThemeChoice,
  });

  final AppThemeChoice themeChoice;
  final ValueChanged<AppThemeChoice> onThemeChoice;

  @override
  State<LogcatPage> createState() => _LogcatPageState();
}

class _LogcatPageState extends State<LogcatPage> {
  final List<LogEntry> _lines = [];
  List<LogEntry> _visible = const [];

  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final _pkgCtrl = TextEditingController();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;

  String _connection = 'connecting';
  String _serverStatus = '';
  int? _appPid;

  List<DeviceInfo> _devices = const [];
  String? _activeDevice;
  String? _pickedDevice;

  List<FilterPreset> _presets = const [];

  String _search = '';
  String _minLevel = 'V';
  bool _paused = false;
  bool _wrap = true;
  bool _autoScroll = true;
  bool _useRegex = false;

  LogColumnConfig _columns = const LogColumnConfig();

  @override
  void initState() {
    super.initState();
    _initBridgeAndConnect();
    _scroll.addListener(_onScroll);
    loadColumnConfig().then((c) {
      if (mounted) setState(() => _columns = c);
    });
    loadFilterPresets().then((p) {
      if (mounted) setState(() => _presets = p);
    });
  }

  void _updateColumns(LogColumnConfig next) {
    setState(() => _columns = next);
    saveColumnConfig(next);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final current = _scroll.offset;
    final atBottom = max <= 0 || current >= (max - 50);
    if (atBottom && !_autoScroll) {
      setState(() => _autoScroll = true);
    } else if (!atBottom && _autoScroll) {
      setState(() => _autoScroll = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_autoScroll && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _initBridgeAndConnect() async {
    await ensureBridgeRunning();
    if (mounted) {
      _connect();
    }
  }

  @override
  void dispose() {
    _reconnect?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _searchCtrl.dispose();
    _pkgCtrl.dispose();
    stopBridge();
    super.dispose();
  }

  // ------------------------------------------------------------- connection

  Uri get _serverUri {
    final host = Uri.base.host.isEmpty ? '127.0.0.1' : Uri.base.host;
    return Uri.parse('ws://$host:8080/ws');
  }

  Future<void> _connect() async {
    _reconnect?.cancel();
    setState(() => _connection = 'connecting');

    final ch = WebSocketChannel.connect(_serverUri);
    try {
      await ch.ready;
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    if (!mounted) return;
    _channel = ch;
    _sub = ch.stream.listen(
      _onMessage,
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
    );
    setState(() => _connection = 'live');
  }

  void _scheduleReconnect() {
    if (!mounted) return;
    setState(() => _connection = 'offline');
    _sub?.cancel();
    _channel = null;
    _reconnect = Timer(const Duration(seconds: 2), _connect);
  }

  void _send(Map<String, dynamic> cmd) => _channel?.sink.add(jsonEncode(cmd));

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;

    switch (msg['type']) {
      case 'history':
        _lines
          ..clear()
          ..addAll(
            (msg['lines'] as List).map(
              (e) => LogEntry.fromJson(e as Map<String, dynamic>),
            ),
          );
        _recompute();
        if (_autoScroll) {
          _scrollToBottom();
        }
        break;

      case 'lines':
        if (_paused) return;
        _lines.addAll(
          (msg['lines'] as List).map(
            (e) => LogEntry.fromJson(e as Map<String, dynamic>),
          ),
        );
        final maxCapacity = _autoScroll ? kMaxLines : kMaxLines * 2;
        if (_lines.length > maxCapacity) {
          _lines.removeRange(0, _lines.length - maxCapacity);
        }
        _recompute();
        if (_autoScroll) {
          _scrollToBottom();
        }
        break;

      case 'clear':
        _lines.clear();
        _recompute();
        break;

      case 'status':
        setState(() {
          _serverStatus = msg['status'] as String? ?? '';
          _appPid = msg['pid'] as int?;
          _devices =
              (msg['devices'] as List? ?? [])
                  .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
                  .toList();
          _activeDevice = msg['device'] as String?;
        });
        break;
    }
  }

  // ---------------------------------------------------------------- filters

  void _recompute() {
    final min = _levels.indexOf(_minLevel);
    final q = _search;
    final qLower = q.toLowerCase();

    RegExp? re;
    if (_useRegex && q.isNotEmpty) {
      try {
        re = RegExp(q, caseSensitive: false);
      } catch (_) {
        // Invalid regex pattern while user is typing
      }
    }

    setState(() {
      _visible = _lines
          .where((e) {
            if (e.rank < min) return false;
            if (q.isEmpty) return true;
            if (_useRegex) {
              return re != null && (re.hasMatch(e.msg) || re.hasMatch(e.tag));
            }
            return e.msg.toLowerCase().contains(qLower) ||
                e.tag.toLowerCase().contains(qLower);
          })
          .toList(growable: false);
    });
  }

  void _applyPackage() {
    _send({'cmd': 'filter', 'package': _pkgCtrl.text.trim()});
  }

  void _applyDevice(String? serial) {
    setState(() => _pickedDevice = serial);
    _send({'cmd': 'device', 'serial': serial ?? ''});
  }

  void _notify(
    String message, {
    bool isError = false,
  }) {
    if (!mounted) return;
    final palette = context.palette;
    final sm = ScaffoldMessenger.maybeOf(context);
    if (sm == null) return;
    sm.hideCurrentSnackBar();
    sm.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            fontSize: 12,
            color: isError ? Colors.white : palette.text,
          ),
        ),
        backgroundColor: isError ? const Color(0xFFC5333D) : palette.panel,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: isError ? Colors.transparent : palette.border),
        ),
      ),
    );
  }

  Future<void> _export() async {
    final buf = StringBuffer();
    for (final e in _visible) {
      final parts = <String>[];
      if (_columns.showTime) parts.add(e.time);
      if (_columns.showPidTid) parts.add('${e.pid}-${e.tid}');
      if (_columns.showPackage) {
        final pkg =
            e.pkg ??
            (_appPid != null && e.pid == _appPid ? _pkgCtrl.text.trim() : null);
        if (pkg != null && pkg.isNotEmpty) parts.add(pkg);
      }
      if (_columns.showLevel && _columns.showTag) {
        parts.add('${e.level}/${e.tag}:');
      } else {
        if (_columns.showLevel) parts.add('[${e.level}]');
        if (_columns.showTag) parts.add('${e.tag}:');
      }
      parts.add(e.msg);
      buf.writeln(parts.join(' '));
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final filename = 'logcat_$stamp.log';

    String result;
    bool isError = false;
    try {
      result = await exportLog(buf.toString(), filename);
    } catch (e) {
      result = 'export failed: $e';
      isError = true;
    }

    _notify(
      result,
      isError: isError,
    );
  }

  // ------------------------------------------------------------------ presets

  Future<void> _savePreset(String name) async {
    final preset = FilterPreset(
      name: name,
      package: _pkgCtrl.text.trim(),
      search: _searchCtrl.text,
      minLevel: _minLevel,
      useRegex: _useRegex,
    );
    final next = [..._presets.where((p) => p.name != name), preset];
    setState(() => _presets = next);
    await saveFilterPresets(next);
  }

  Future<void> _deletePreset(FilterPreset preset) async {
    final next = _presets.where((p) => p.name != preset.name).toList();
    setState(() => _presets = next);
    await saveFilterPresets(next);
  }

  void _applyPreset(FilterPreset preset) {
    _pkgCtrl.text = preset.package;
    _searchCtrl.text = preset.search;
    setState(() {
      _minLevel = preset.minLevel;
      _useRegex = preset.useRegex;
      _search = preset.search;
    });
    _recompute();
    _applyPackage();
  }

  Future<void> _showPresetsDialog() async {
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
                          Icon(Icons.bookmark_outline, size: 18, color: palette.accent),
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
                                style: TextStyle(fontSize: 12, color: palette.text),
                                decoration: InputDecoration(
                                  hintText: 'Preset name',
                                  hintStyle: TextStyle(fontSize: 12, color: palette.dim),
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
                              await _savePreset(name);
                              nameCtrl.clear();
                              setDialogState(() {});
                            },
                            child: const Text('Save current', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (_presets.isEmpty)
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
                            itemCount: _presets.length,
                            separatorBuilder:
                                (_, __) => Divider(
                                  height: 1,
                                  color: palette.border,
                                ),
                            itemBuilder: (context, i) {
                              final p = _presets[i];
                              final details = [
                                if (p.package.isNotEmpty) 'pkg: ${p.package}',
                                'level: ${p.minLevel}+',
                                if (p.search.isNotEmpty)
                                  '${p.useRegex ? 're' : 'search'}: ${p.search}',
                              ].join('  ·  ');
                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  hoverColor: palette.selectedBg.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(4),
                                  onTap: () {
                                    _applyPreset(p);
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
                                            await _deletePreset(p);
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
                            style: TextButton.styleFrom(foregroundColor: palette.text),
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

  Future<void> _showColumnConfigDialog() async {
    final palette = context.palette;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Widget presetBtn(String label, LogColumnConfig config) {
              final active =
                  _columns.showTime == config.showTime &&
                  _columns.showPidTid == config.showPidTid &&
                  _columns.showPackage == config.showPackage &&
                  _columns.showLevel == config.showLevel &&
                  _columns.showTag == config.showTag;
              if (active) {
                return FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  onPressed: () {},
                  child: Text(label, style: const TextStyle(fontSize: 11)),
                );
              }
              return OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.text,
                  side: BorderSide(color: palette.border),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                onPressed: () {
                  _updateColumns(config);
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
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
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
                        subtitle: 'Date and invocation time (e.g. 10-04 19:45:12.345)',
                        value: _columns.showTime,
                        onChanged: (v) {
                          if (v != null) {
                            _updateColumns(_columns.copyWith(showTime: v));
                            setDialogState(() {});
                          }
                        },
                      ),
                      columnCheckbox(
                        title: 'Process / Thread (PID-TID)',
                        subtitle: 'Process and thread IDs (e.g. 1234-5678)',
                        value: _columns.showPidTid,
                        onChanged: (v) {
                          if (v != null) {
                            _updateColumns(_columns.copyWith(showPidTid: v));
                            setDialogState(() {});
                          }
                        },
                      ),
                      columnCheckbox(
                        title: 'App Package Name (PACKAGE)',
                        subtitle: 'Application ID or process name (e.g. com.example.app)',
                        value: _columns.showPackage,
                        onChanged: (v) {
                          if (v != null) {
                            _updateColumns(_columns.copyWith(showPackage: v));
                            setDialogState(() {});
                          }
                        },
                      ),
                      columnCheckbox(
                        title: 'Log Level (LVL)',
                        subtitle: 'Severity badge (V, D, I, W, E, F)',
                        value: _columns.showLevel,
                        onChanged: (v) {
                          if (v != null) {
                            _updateColumns(_columns.copyWith(showLevel: v));
                            setDialogState(() {});
                          }
                        },
                      ),
                      columnCheckbox(
                        title: 'Tag (TAG)',
                        subtitle: 'Component tag (e.g. ActivityManager)',
                        value: _columns.showTag,
                        onChanged: (v) {
                          if (v != null) {
                            _updateColumns(_columns.copyWith(showTag: v));
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
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
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

  List<PopupMenuEntry<void>> _buildColumnMenuItems(AppPalette palette) {
    return [
      CheckedPopupMenuItem<void>(
        checked: _columns.showTime,
        value: null,
        onTap: () => _updateColumns(_columns.copyWith(showTime: !_columns.showTime)),
        child: Text('Timestamp (TIME)', style: TextStyle(fontSize: 12, color: palette.text)),
      ),
      CheckedPopupMenuItem<void>(
        checked: _columns.showPidTid,
        value: null,
        onTap: () => _updateColumns(_columns.copyWith(showPidTid: !_columns.showPidTid)),
        child: Text('PID-TID', style: TextStyle(fontSize: 12, color: palette.text)),
      ),
      CheckedPopupMenuItem<void>(
        checked: _columns.showPackage,
        value: null,
        onTap: () => _updateColumns(_columns.copyWith(showPackage: !_columns.showPackage)),
        child: Text('Package Name', style: TextStyle(fontSize: 12, color: palette.text)),
      ),
      CheckedPopupMenuItem<void>(
        checked: _columns.showLevel,
        value: null,
        onTap: () => _updateColumns(_columns.copyWith(showLevel: !_columns.showLevel)),
        child: Text('Log Level (LVL)', style: TextStyle(fontSize: 12, color: palette.text)),
      ),
      CheckedPopupMenuItem<void>(
        checked: _columns.showTag,
        value: null,
        onTap: () => _updateColumns(_columns.copyWith(showTag: !_columns.showTag)),
        child: Text('Tag (TAG)', style: TextStyle(fontSize: 12, color: palette.text)),
      ),
      const PopupMenuDivider(),
      PopupMenuItem<void>(
        onTap: () => _updateColumns(LogColumnConfig.standard),
        child: Text('Reset: Standard View (All)', style: TextStyle(fontSize: 12, color: palette.text)),
      ),
      PopupMenuItem<void>(
        onTap: () => _updateColumns(LogColumnConfig.compact),
        child: Text('Preset: Compact View', style: TextStyle(fontSize: 12, color: palette.text)),
      ),
      PopupMenuItem<void>(
        onTap: () => _updateColumns(LogColumnConfig.messageOnly),
        child: Text('Preset: Message Only', style: TextStyle(fontSize: 12, color: palette.text)),
      ),
    ];
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      backgroundColor: palette.bg,
      body: Column(
        children: [
          // Top horizontal filter bar
          _TopFilterBar(
            searchCtrl: _searchCtrl,
            pkgCtrl: _pkgCtrl,
            minLevel: _minLevel,
            useRegex: _useRegex,
            appPid: _appPid,
            devices: _devices,
            pickedDevice: _pickedDevice,
            onSearch: (v) {
              _search = v;
              _recompute();
            },
            onLevel: (v) {
              _minLevel = v;
              _recompute();
            },
            onPackage: _applyPackage,
            onRegex:
                () => setState(() {
                  _useRegex = !_useRegex;
                  _recompute();
                }),
            onDevice: _applyDevice,
          ),
          // Main log console area with left vertical action strip
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left vertical action toolbar
                _LeftVerticalToolbar(
                  paused: _paused,
                  wrap: _wrap,
                  atBottom: _autoScroll,
                  themeChoice: widget.themeChoice,
                  onPause: () => setState(() => _paused = !_paused),
                  onWrap: () => setState(() => _wrap = !_wrap),
                  onScrollToEnd: () {
                    setState(() => _autoScroll = true);
                    _scrollToBottom();
                  },
                  onScrollToTop: () {
                    setState(() => _autoScroll = false);
                    if (_scroll.hasClients) {
                      _scroll.jumpTo(0);
                    }
                  },
                  onClear: () => _send({'cmd': 'clear'}),
                  onRestart: () => _send({'cmd': 'restart'}),
                  onExport: _export,
                  onPresets: _showPresetsDialog,
                  onConfigureColumns: _showColumnConfigDialog,
                  onThemeChoice: widget.onThemeChoice,
                ),
                // Log entries and column headers
                Expanded(
                  child: Column(
                    children: [
                      _columnHeader(palette),
                      Expanded(
                        child: Stack(
                          children: [
                            _logList(),
                            if (!_autoScroll)
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
                                    onPressed: () {
                                      setState(() => _autoScroll = true);
                                      _scrollToBottom();
                                    },
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
                  ),
                ),
              ],
            ),
          ),
          _statusBar(),
        ],
      ),
    );
  }

  Widget _columnHeader(AppPalette palette) {
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
          if (_columns.showTime) ...[
            SizedBox(
              width: 110,
              child: Text(
                'TIME',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (_columns.showPidTid) ...[
            SizedBox(
              width: 82,
              child: Text(
                'PID-TID',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (_columns.showPackage) ...[
            SizedBox(
              width: 140,
              child: Text(
                'PACKAGE',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (_columns.showLevel) ...[
            SizedBox(
              width: 26,
              child: Text(
                'LVL',
                style: headerStyle.copyWith(color: palette.dim),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (_columns.showTag) ...[
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
                  Text('Columns', style: TextStyle(fontSize: 11, color: palette.dim)),
                ],
              ),
            ),
            itemBuilder: (context) => _buildColumnMenuItems(palette),
          ),
        ],
      ),
    );
  }

  Widget _logList() {
    if (_visible.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.phone_android,
              size: 36,
              color: context.palette.dim.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 10),
            Text(
              _lines.isEmpty
                  ? 'Waiting for log output...'
                  : 'Nothing matches the current filter.',
              style: TextStyle(color: context.palette.dim, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return SelectionArea(
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        interactive: true,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 2),
          itemCount: _visible.length,
          itemBuilder: (context, i) {
            final e = _visible[i];
            return _LogRow(
              key: ValueKey(e.seq),
              entry: e,
              columns: _columns,
              wrap: _wrap,
              appPid: _appPid,
              packageFilter: _pkgCtrl.text.trim(),
              onCopy: () => _copy(e),
              onFilterTag: () {
                _searchCtrl.text = e.tag;
                _search = e.tag;
                _recompute();
              },
              onFilterPackage: (pkg) {
                _pkgCtrl.text = pkg;
                _applyPackage();
              },
            );
          },
        ),
      ),
    );
  }

  void _copy(LogEntry e) {
    final parts = <String>[];
    if (_columns.showTime) parts.add(e.time);
    if (_columns.showPidTid) parts.add('${e.pid}-${e.tid}');
    if (_columns.showPackage) {
      final pkg =
          e.pkg ??
          (_appPid != null && e.pid == _appPid ? _pkgCtrl.text.trim() : null);
      if (pkg != null && pkg.isNotEmpty) parts.add(pkg);
    }
    if (_columns.showLevel && _columns.showTag) {
      parts.add('${e.level}/${e.tag}:');
    } else {
      if (_columns.showLevel) parts.add('[${e.level}]');
      if (_columns.showTag) parts.add('${e.tag}:');
    }
    parts.add(e.msg);

    Clipboard.setData(ClipboardData(text: parts.join(' ')));
    _notify('Log line copied to clipboard');
  }

  Widget _statusBar() {
    final palette = context.palette;
    final live = _connection == 'live';
    final textStyle = TextStyle(color: palette.statusBarText, fontSize: 11);
    final dotColor = switch (_connection) {
      'live' => palette.levelColor['I'],
      'connecting' => palette.levelColor['W'],
      _ => palette.levelColor['E'],
    };

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: palette.statusBarBg,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
          ),
          const SizedBox(width: 7),
          Text(live ? _serverStatus : _connection, style: textStyle),
          if (_activeDevice != null) ...[
            const SizedBox(width: 12),
            Container(width: 1, height: 12, color: palette.border),
            const SizedBox(width: 12),
            Icon(Icons.phone_android, size: 13, color: palette.dim),
            const SizedBox(width: 4),
            Text(
              _devices
                  .firstWhere(
                    (d) => d.serial == _activeDevice,
                    orElse: () => DeviceInfo(serial: _activeDevice!),
                  )
                  .label,
              style: textStyle,
            ),
          ],
          if (_appPid != null) ...[
            const SizedBox(width: 12),
            Container(width: 1, height: 12, color: palette.border),
            const SizedBox(width: 12),
            Icon(Icons.android, size: 13, color: palette.dim),
            const SizedBox(width: 4),
            Text('PID: $_appPid', style: textStyle),
          ],
          const Spacer(),
          if (_paused) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: palette.levelColor['W']?.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'PAUSED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: palette.levelColor['W'],
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (!_autoScroll) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: palette.accent.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                'SCROLL PAUSED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: palette.accent,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Text(
            '${_visible.length} of ${_lines.length} lines',
            style: textStyle,
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ toolbar

AppThemeChoice _nextThemeChoice(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => AppThemeChoice.light,
  AppThemeChoice.light => AppThemeChoice.darkModern,
  AppThemeChoice.darkModern => AppThemeChoice.vsDark,
  AppThemeChoice.vsDark => AppThemeChoice.system,
};

IconData _themeChoiceIcon(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => Icons.brightness_auto,
  AppThemeChoice.light => Icons.light_mode,
  AppThemeChoice.darkModern => Icons.dark_mode,
  AppThemeChoice.vsDark => Icons.contrast,
};

String _themeChoiceLabel(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => 'Theme: Auto (System)',
  AppThemeChoice.light => 'Theme: Modern Light',
  AppThemeChoice.darkModern => 'Theme: Dark Modern',
  AppThemeChoice.vsDark => 'Theme: VS Dark',
};

class _TopFilterBar extends StatelessWidget {
  const _TopFilterBar({
    required this.searchCtrl,
    required this.pkgCtrl,
    required this.minLevel,
    required this.useRegex,
    required this.appPid,
    required this.devices,
    required this.pickedDevice,
    required this.onSearch,
    required this.onLevel,
    required this.onPackage,
    required this.onRegex,
    required this.onDevice,
  });

  final TextEditingController searchCtrl;
  final TextEditingController pkgCtrl;
  final String minLevel;
  final bool useRegex;
  final int? appPid;
  final List<DeviceInfo> devices;
  final String? pickedDevice;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onLevel;
  final VoidCallback onPackage;
  final VoidCallback onRegex;
  final ValueChanged<String?> onDevice;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          // Device selector dropdown
          _devicePicker(palette),
          const SizedBox(width: 8),

          // Process / package filter field
          _processField(palette),
          const SizedBox(width: 8),

          // Unified search input with regex and clear
          _searchField(palette),
          const SizedBox(width: 8),

          // Level dropdown (Verbose, Debug, Info, Warn, Error, Assert)
          _levelDropdown(palette),
        ],
      ),
    );
  }

  Widget _devicePicker(AppPalette palette) {
    final value =
        devices.any((d) => d.serial == pickedDevice) ? pickedDevice : null;

    return Container(
      width: 215,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: value,
          isDense: true,
          dropdownColor: palette.panel,
          icon: Icon(Icons.arrow_drop_down, size: 16, color: palette.dim),
          hint: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phone_android, size: 14, color: palette.dim),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  devices.isEmpty ? 'No device' : 'Auto-select',
                  style: TextStyle(fontSize: 12, color: palette.dim),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          devices.isNotEmpty
                              ? palette.levelColor['I']
                              : palette.dim,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('Auto-select', style: TextStyle(fontSize: 12, color: palette.text)),
                ],
              ),
            ),
            for (final d in devices)
              DropdownMenuItem<String?>(
                value: d.serial,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            d.authorized
                                ? palette.levelColor['I']
                                : palette.levelColor['W'],
                      ),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        d.label,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 12,
                          color: d.authorized ? palette.text : palette.dim,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          onChanged: devices.isEmpty ? null : onDevice,
        ),
      ),
    );
  }

  Widget _processField(AppPalette palette) {
    return SizedBox(
      height: 32,
      width: 185,
      child: TextField(
        controller: pkgCtrl,
        onSubmitted: (_) => onPackage(),
        style: TextStyle(fontSize: 12, color: palette.text),
        decoration: InputDecoration(
          hintText: 'package:mine or pkg',
          hintStyle: TextStyle(fontSize: 12, color: palette.dim),
          filled: true,
          fillColor: palette.bg,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          prefixIcon: Icon(Icons.phone_android, size: 13, color: palette.dim),
          prefixIconConstraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          suffixIconConstraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pkgCtrl.text.isNotEmpty)
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                  icon: Icon(Icons.close, size: 12, color: palette.dim),
                  onPressed: () {
                    pkgCtrl.clear();
                    onPackage();
                  },
                )
              else if (appPid != null)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: palette.accentBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$appPid',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: palette.accent,
                    ),
                  ),
                ),
            ],
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
    );
  }

  Widget _searchField(AppPalette palette) {
    return Expanded(
      child: SizedBox(
        height: 32,
        child: TextField(
          controller: searchCtrl,
          onChanged: onSearch,
          style: TextStyle(fontSize: 12, color: palette.text),
          decoration: InputDecoration(
            hintText: 'Filter (tag, message, or text)...',
            hintStyle: TextStyle(fontSize: 12, color: palette.dim),
            filled: true,
            fillColor: palette.bg,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            prefixIcon: Icon(Icons.search, size: 14, color: palette.dim),
            prefixIconConstraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            suffixIconConstraints: const BoxConstraints(minWidth: 60, minHeight: 26),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: 'Toggle Regex (.*)',
                  child: InkWell(
                    onTap: onRegex,
                    borderRadius: BorderRadius.circular(3),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: useRegex ? palette.accentBg : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: useRegex ? palette.accent : Colors.transparent,
                        ),
                      ),
                      child: Text(
                        '.*',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: useRegex ? palette.accent : palette.dim,
                        ),
                      ),
                    ),
                  ),
                ),
                if (searchCtrl.text.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Clear search',
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                      icon: Icon(Icons.close, size: 12, color: palette.dim),
                      onPressed: () {
                        searchCtrl.clear();
                        onSearch('');
                      },
                    ),
                  ),
                ],
                const SizedBox(width: 6),
              ],
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
    );
  }

  Widget _levelDropdown(AppPalette palette) {
    return Container(
      width: 125,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: minLevel,
          isDense: true,
          dropdownColor: palette.panel,
          icon: Icon(Icons.arrow_drop_down, size: 16, color: palette.dim),
          items:
              _levels.map((l) {
                final col = palette.levelColor[l] ?? palette.dim;
                return DropdownMenuItem<String>(
                  value: l,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: col,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        _levelNames[l] ?? l,
                        style: TextStyle(fontSize: 12, color: palette.text),
                      ),
                    ],
                  ),
                );
              }).toList(),
          onChanged: (v) {
            if (v != null) onLevel(v);
          },
        ),
      ),
    );
  }
}

// -------------------------------------------------------- left vertical toolbar

class _LeftVerticalToolbar extends StatelessWidget {
  const _LeftVerticalToolbar({
    required this.paused,
    required this.wrap,
    required this.atBottom,
    required this.themeChoice,
    required this.onPause,
    required this.onWrap,
    required this.onScrollToEnd,
    required this.onScrollToTop,
    required this.onClear,
    required this.onRestart,
    required this.onExport,
    required this.onPresets,
    required this.onConfigureColumns,
    required this.onThemeChoice,
  });

  final bool paused;
  final bool wrap;
  final bool atBottom;
  final AppThemeChoice themeChoice;
  final VoidCallback onPause;
  final VoidCallback onWrap;
  final VoidCallback onScrollToEnd;
  final VoidCallback onScrollToTop;
  final VoidCallback onClear;
  final VoidCallback onRestart;
  final VoidCallback onExport;
  final VoidCallback onPresets;
  final VoidCallback onConfigureColumns;
  final ValueChanged<AppThemeChoice> onThemeChoice;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: 42,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(right: BorderSide(color: palette.border)),
      ),
      child: Column(
        children: [
          // Clear Logcat
          _toolButton(
            icon: Icons.delete_sweep_outlined,
            tooltip: 'Clear Logcat (Ctrl+L)',
            onTap: onClear,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Pause / Resume
          _toolButton(
            icon: paused ? Icons.play_arrow : Icons.pause,
            tooltip: paused ? 'Resume Logcat' : 'Pause Logcat',
            onTap: onPause,
            active: paused,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Scroll to the end
          _toolButton(
            icon: Icons.arrow_downward,
            tooltip: 'Scroll to the end',
            onTap: onScrollToEnd,
            active: atBottom,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Scroll to the top
          _toolButton(
            icon: Icons.arrow_upward,
            tooltip: 'Scroll to the top',
            onTap: onScrollToTop,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Soft-wrap lines
          _toolButton(
            icon: Icons.wrap_text,
            tooltip: 'Soft-wrap lines',
            onTap: onWrap,
            active: wrap,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Configure visible columns / formatting
          _toolButton(
            icon: Icons.view_column_outlined,
            tooltip: 'Configure Columns / Log Format',
            onTap: onConfigureColumns,
            palette: palette,
          ),
          const SizedBox(height: 6),
          Container(width: 24, height: 1, color: palette.border),
          const SizedBox(height: 6),

          // Filter Presets
          _toolButton(
            icon: Icons.bookmark_outline,
            tooltip: 'Filter Presets',
            onTap: onPresets,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Export Logs
          _toolButton(
            icon: Icons.download,
            tooltip: 'Export Logs',
            onTap: onExport,
            palette: palette,
          ),
          const SizedBox(height: 4),

          // Restart ADB
          _toolButton(
            icon: Icons.refresh,
            tooltip: 'Restart ADB',
            onTap: onRestart,
            palette: palette,
          ),
          const Spacer(),

          // Theme switcher
          _toolButton(
            icon: _themeChoiceIcon(themeChoice),
            tooltip: _themeChoiceLabel(themeChoice),
            onTap: () => onThemeChoice(_nextThemeChoice(themeChoice)),
            palette: palette,
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
    required AppPalette palette,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          padding: EdgeInsets.zero,
          icon: Icon(
            icon,
            size: 16,
            color: active ? palette.accent : palette.dim,
          ),
          style: IconButton.styleFrom(
            backgroundColor: active ? palette.accentBg : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: BorderSide(
                color: active ? palette.accent : Colors.transparent,
              ),
            ),
          ),
          onPressed: onTap,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------- row

class _LogRow extends StatefulWidget {
  const _LogRow({
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
  State<_LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<_LogRow> {
  bool _hovered = false;

  void _showContextMenu(TapDownDetails details) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
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
              Text(
                'Filter by tag: "${widget.entry.tag}"',
                style: TextStyle(fontSize: 12, color: palette.text),
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
                Text(
                  'Filter by package: "${widget.entry.pkg}"',
                  style: TextStyle(fontSize: 12, color: palette.text),
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
                    icon: Icon(
                      Icons.copy,
                      size: 12,
                      color: palette.dim,
                    ),
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
