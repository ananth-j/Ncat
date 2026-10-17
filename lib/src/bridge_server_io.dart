import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int kHistorySize = 3000;
const Duration kFlushInterval = Duration(milliseconds: 100);
const Duration kPidPollInterval = Duration(seconds: 2);

/// Resolves the adb binary path by checking environment variables,
/// system PATH, and standard platform SDK directories.
String findAdbPath() {
  final env = Platform.environment['ADB'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) {
    return env;
  }

  // Check if standard 'adb' command is executable in PATH
  try {
    final res = Process.runSync('adb', ['version']);
    if (res.exitCode == 0) return 'adb';
  } catch (_) {}

  // Fallbacks by OS
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      final p = '$localAppData\\Android\\sdk\\platform-tools\\adb.exe';
      if (File(p).existsSync()) return p;
    }
    final androidHome = Platform.environment['ANDROID_HOME'] ??
        Platform.environment['ANDROID_SDK_ROOT'];
    if (androidHome != null && androidHome.isNotEmpty) {
      final p = '$androidHome\\platform-tools\\adb.exe';
      if (File(p).existsSync()) return p;
    }
    const standardWin = r'C:\Android\platform-tools\adb.exe';
    if (File(standardWin).existsSync()) return standardWin;
  } else if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final p = '$home/Library/Android/sdk/platform-tools/adb';
      if (File(p).existsSync()) return p;
    }
    for (final p in ['/opt/homebrew/bin/adb', '/usr/local/bin/adb']) {
      if (File(p).existsSync()) return p;
    }
  } else if (Platform.isLinux) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final p = '$home/Android/Sdk/platform-tools/adb';
      if (File(p).existsSync()) return p;
    }
    if (File('/usr/bin/adb').existsSync()) return '/usr/bin/adb';
  }

  return 'adb';
}

class ServerDeviceInfo {
  ServerDeviceInfo(this.serial, this.model, {this.isAuthorized = true});
  final String serial;
  final String? model;
  final bool isAuthorized;

  Map<String, dynamic> toJson() => {
        'serial': serial,
        'model': model,
        'authorized': isAuthorized,
      };
}

class LogcatBridgeServer {
  LogcatBridgeServer({
    this.port = 8080,
    this.webRoot,
    String? adbPath,
    this.onLog,
  }) : adbPath = adbPath ?? findAdbPath();

  final int port;
  final String? webRoot;
  final String adbPath;
  final void Function(String text)? onLog;

  HttpServer? _server;
  Process? _adb;
  String? _packageFilter;
  int? _appPid;
  int _seq = 0;
  String _statusText = 'starting';

  List<ServerDeviceInfo> _devices = [];
  List<String> _lastDeviceSerials = [];
  String? _selectedDevice;

  final Set<WebSocket> _clients = {};
  final List<Map<String, dynamic>> _history = [];
  final List<Map<String, dynamic>> _pending = [];

  Timer? _flushTimer;
  Timer? _pidTimer;
  Timer? _deviceTimer;
  Timer? _startRetryTimer;

  bool _isDisposed = false;
  final Map<int, String> _pidToProcess = {};
  int _psTicks = 0;

  final RegExp _logRe = RegExp(
    r'^(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEFS])\s+(.*?)\s*: ?(.*)$',
  );

  /// Attempts to bind and start the server.
  /// Returns false if the port is already taken by another process.
  Future<bool> start() async {
    _isDisposed = false;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException catch (_) {
      // Port in use (an external bridge or other service is already active)
      return false;
    } catch (_) {
      return false;
    }

    _log('logcat bridge listening on http://localhost:$port');
    if (webRoot != null) _log('serving web build from $webRoot');
    _log('adb: $adbPath');

    _flushTimer = Timer.periodic(kFlushInterval, (_) => _flush());
    _pidTimer = Timer.periodic(kPidPollInterval, (_) => _resolvePid());
    _deviceTimer = Timer.periodic(kPidPollInterval, (_) => _pollDevices());

    unawaited(_startLogcat());

    _listenServer();
    return true;
  }

  void _listenServer() async {
    final server = _server;
    if (server == null) return;

    try {
      await for (final req in server) {
        if (_isDisposed) break;
        if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
          final socket = await WebSocketTransformer.upgrade(req);
          _onClient(socket);
        } else if (webRoot != null) {
          await _serveStatic(req, webRoot!);
        } else {
          req.response
            ..statusCode = HttpStatus.notFound
            ..write('logcat bridge. connect a websocket to /ws');
          await req.response.close();
        }
      }
    } catch (_) {
      // Server closed
    }
  }

  Future<void> stop() async {
    _isDisposed = true;
    _startRetryTimer?.cancel();
    _flushTimer?.cancel();
    _pidTimer?.cancel();
    _deviceTimer?.cancel();

    _adb?.kill();
    _adb = null;

    for (final c in _clients.toList()) {
      try {
        await c.close();
      } catch (_) {}
    }
    _clients.clear();

    await _server?.close(force: true);
    _server = null;
    _log('logcat bridge stopped');
  }

  void _log(String text) {
    if (onLog != null) {
      onLog!(text);
    }
  }

  // ------------------------------------------------------------- adb process

  Future<void> _startLogcat() async {
    if (_isDisposed) return;
    await _refreshDevices();
    final serial = _activeSerial();
    if (serial == null) {
      final unauthorized = _devices.where((d) => !d.isAuthorized).toList();
      if (unauthorized.isNotEmpty) {
        _setStatus('unauthorized');
        _system(
          'Device ${unauthorized.first.serial} is unauthorized. Unlock phone & accept USB debugging prompt.',
        );
      } else {
        _setStatus('no device');
        _system('No device found. Plug in a device or start an emulator.');
      }
      _startRetryTimer?.cancel();
      _startRetryTimer = Timer(const Duration(seconds: 3), _startLogcat);
      return;
    }

    try {
      await Process.run(adbPath, ['-s', serial, 'logcat', '-c']);
    } catch (_) {
      // Clearing is best-effort
    }

    if (_isDisposed) return;

    try {
      final p = await Process.start(
        adbPath,
        ['-s', serial, 'logcat', '-v', 'threadtime'],
      );
      _adb = p;
      _setStatus('connected');
      _system('logcat started on $serial');

      p.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_onLine, onError: (Object e) => _system('stdout error: $e'));

      p.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((l) => _system('adb: $l'));

      unawaited(p.exitCode.then((code) {
        _adb = null;
        if (!_isDisposed) {
          _setStatus('disconnected');
          _system('logcat exited ($code) — retrying in 2s');
          _startRetryTimer?.cancel();
          _startRetryTimer = Timer(const Duration(seconds: 2), _startLogcat);
        }
      }));
    } on ProcessException catch (e) {
      _setStatus('adb not found');
      _system('Could not run "$adbPath": ${e.message}');
      _startRetryTimer?.cancel();
      _startRetryTimer = Timer(const Duration(seconds: 5), _startLogcat);
    }
  }

  String? _activeSerial() {
    final authorized = _devices.where((d) => d.isAuthorized).toList();
    if (_selectedDevice != null &&
        authorized.any((d) => d.serial == _selectedDevice)) {
      return _selectedDevice;
    }
    return authorized.isEmpty ? null : authorized.first.serial;
  }

  Future<void> _refreshDevices() async {
    try {
      final r = await Process.run(adbPath, ['devices', '-l']);
      final devices = <ServerDeviceInfo>[];
      for (final line in (r.stdout as String).split('\n').skip(1)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;

        final state = parts[1];
        if (state == 'unauthorized') {
          devices.add(ServerDeviceInfo(
            parts[0],
            'Unauthorized (Accept USB debugging)',
            isAuthorized: false,
          ));
          continue;
        }
        if (state == 'offline') {
          devices.add(ServerDeviceInfo(
            parts[0],
            'Offline',
            isAuthorized: false,
          ));
          continue;
        }
        if (state != 'device') continue;

        String? model;
        for (final p in parts.skip(2)) {
          if (p.startsWith('model:')) model = p.substring(6);
        }
        devices.add(ServerDeviceInfo(parts[0], model, isAuthorized: true));
      }
      _devices = devices;
    } catch (_) {
      _devices = [];
    }
  }

  Future<void> _pollDevices() async {
    await _refreshDevices();
    final serials = _devices.map((d) => '${d.serial}:${d.isAuthorized}').toList();
    if (serials.length != _lastDeviceSerials.length ||
        !serials.every(_lastDeviceSerials.contains)) {
      _lastDeviceSerials = serials;
      _broadcastStatus();

      // If adb is idle and an authorized device is now present, start logcat immediately
      if (_adb == null && _activeSerial() != null) {
        _startRetryTimer?.cancel();
        unawaited(_startLogcat());
      }
    }
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;

    final m = _logRe.firstMatch(line);
    if (m == null) {
      _pending.add(_entry('', 0, 0, 'V', '--', line));
      return;
    }

    final pid = int.parse(m.group(2)!);
    if (_packageFilter != null && pid != _appPid) return;

    _pending.add(_entry(
      m.group(1)!,
      pid,
      int.parse(m.group(3)!),
      m.group(4)!,
      m.group(5)!,
      m.group(6)!,
    ));
  }

  Map<String, dynamic> _entry(
    String time,
    int pid,
    int tid,
    String level,
    String tag,
    String msg,
  ) {
    final pkg = _pidToProcess[pid] ?? (_packageFilter != null && pid == _appPid ? _packageFilter : null);
    return {
      'seq': _seq++,
      'time': time,
      'pid': pid,
      'tid': tid,
      'level': level,
      'tag': tag,
      'msg': msg,
      if (pkg != null) 'pkg': pkg,
    };
  }

  // ------------------------------------------------------------- pid resolution

  Future<void> _resolvePid() async {
    final serial = _activeSerial();
    if (serial == null) {
      _appPid = null;
      return;
    }

    _psTicks++;
    // Periodically update process table so package names are resolved for all logs
    if (_psTicks % 3 == 0 || (_packageFilter != null && _appPid == null)) {
      try {
        final r = await Process.run(adbPath, ['-s', serial, 'shell', 'ps', '-A']);
        for (final l in (r.stdout as String).split('\n')) {
          final cols = l.trim().split(RegExp(r'\s+'));
          if (cols.length >= 9) {
            final p = int.tryParse(cols[1]);
            final name = cols.last;
            if (p != null && name.isNotEmpty) {
              _pidToProcess[p] = name;
            }
          }
        }
      } catch (_) {}
    }

    final pkg = _packageFilter;
    if (pkg == null) {
      _appPid = null;
      return;
    }

    int? pid;
    for (final entry in _pidToProcess.entries) {
      if (entry.value == pkg || entry.value.endsWith(pkg)) {
        pid = entry.key;
        break;
      }
    }

    if (pid == null) {
      try {
        final r = await Process.run(adbPath, ['-s', serial, 'shell', 'pidof', '-s', pkg]);
        pid = int.tryParse((r.stdout as String).trim().split(RegExp(r'\s+')).first);
      } catch (_) {}
    }

    if (pid != _appPid) {
      _appPid = pid;
      _system(pid == null ? '$pkg is not running' : '$pkg → pid $pid');
      _broadcastStatus();
    }
  }

  // ------------------------------------------------------------------- clients

  void _onClient(WebSocket socket) {
    _clients.add(socket);
    socket.add(jsonEncode({'type': 'history', 'lines': _history}));
    socket.add(jsonEncode(_statusMessage()));

    socket.listen(
      (dynamic data) => _onCommand(data),
      onDone: () => _clients.remove(socket),
      onError: (_) => _clients.remove(socket),
      cancelOnError: true,
    );
  }

  Future<void> _onCommand(dynamic data) async {
    Map<String, dynamic> cmd;
    try {
      cmd = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    switch (cmd['cmd']) {
      case 'filter':
        final pkg = (cmd['package'] as String?)?.trim();
        _packageFilter = (pkg == null || pkg.isEmpty) ? null : pkg;
        _appPid = null;
        await _resolvePid();
        _broadcastStatus();
        break;

      case 'clear':
        _history.clear();
        _pending.clear();
        final serial = _activeSerial();
        if (serial != null) {
          try {
            await Process.run(adbPath, ['-s', serial, 'logcat', '-c']);
          } catch (_) {}
        }
        _broadcast({'type': 'clear'});
        break;

      case 'restart':
        _adb?.kill();
        break;

      case 'device':
        final serial = (cmd['serial'] as String?)?.trim();
        _selectedDevice = (serial == null || serial.isEmpty) ? null : serial;
        _history.clear();
        _pending.clear();
        _broadcast({'type': 'clear'});
        if (_adb != null) {
          _adb?.kill();
        } else {
          unawaited(_startLogcat());
        }
        break;
    }
  }

  void _flush() {
    if (_pending.isEmpty) return;

    final batch = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();

    _history.addAll(batch);
    if (_history.length > kHistorySize) {
      _history.removeRange(0, _history.length - kHistorySize);
    }

    _broadcast({'type': 'lines', 'lines': batch});
  }

  void _system(String text) {
    _log('[bridge] $text');
    _pending.add(_entry('', 0, 0, 'I', 'bridge', text));
  }

  void _setStatus(String s) {
    _statusText = s;
    _broadcastStatus();
  }

  Map<String, dynamic> _statusMessage() => {
        'type': 'status',
        'status': _statusText,
        'package': _packageFilter,
        'pid': _appPid,
        'devices': _devices.map((d) => d.toJson()).toList(),
        'device': _activeSerial(),
      };

  void _broadcastStatus() => _broadcast(_statusMessage());

  void _broadcast(Map<String, dynamic> msg) {
    if (_clients.isEmpty) return;
    final encoded = jsonEncode(msg);
    for (final c in _clients.toList()) {
      try {
        c.add(encoded);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  // ------------------------------------------------------------- static files

  Future<void> _serveStatic(HttpRequest req, String root) async {
    var path = req.uri.path;
    if (path == '/' || path.isEmpty) path = '/index.html';

    var file = File('$root$path');
    if (!await file.exists()) file = File('$root/index.html');

    if (!await file.exists()) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    req.response.headers.contentType = _contentTypeFor(file.path);
    await req.response.addStream(file.openRead());
    await req.response.close();
  }

  ContentType _contentTypeFor(String path) {
    if (path.endsWith('.html')) return ContentType.html;
    if (path.endsWith('.js')) return ContentType('application', 'javascript');
    if (path.endsWith('.json')) return ContentType.json;
    if (path.endsWith('.css')) return ContentType('text', 'css');
    if (path.endsWith('.wasm')) return ContentType('application', 'wasm');
    if (path.endsWith('.png')) return ContentType('image', 'png');
    if (path.endsWith('.svg')) return ContentType('image', 'svg+xml');
    return ContentType.binary;
  }
}
