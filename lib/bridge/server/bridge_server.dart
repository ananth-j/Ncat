import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../protocol/messages.dart';
import 'device_session.dart';
import 'runners/adb_tracker.dart';
import 'runners/process_runner.dart';
import 'runners/scrcpy_resolver.dart';

const Duration kFlushInterval = Duration(milliseconds: 100);
const Duration kPidPollInterval = Duration(seconds: 2);

/// Generates a cryptographically secure random token.
String generateAuthToken([int length = 32]) {
  final rand = Random.secure();
  final bytes = List<int>.generate(length, (_) => rand.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

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
    final androidHome =
        Platform.environment['ANDROID_HOME'] ??
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

/// Backwards-compatible device info model for bridge clients.
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

/// Standalone Dart Bridge server managing ADB communication, per-device sessions,
/// and WebSocket/HTTP multiplexing.
class LogcatBridgeServer {
  LogcatBridgeServer({
    this.port = 8080,
    this.webRoot,
    String? adbPath,
    this.processRunner = const RealProcessRunner(),
    this.onLog,
    String? authToken,
    bool requireAuth = false,
  }) : adbPath = adbPath ?? findAdbPath(),
       authToken =
           (requireAuth && (authToken == null || authToken.isEmpty))
               ? generateAuthToken()
               : authToken;

  final int port;
  final String? webRoot;
  final String adbPath;
  final ProcessRunner processRunner;
  final void Function(String text)? onLog;
  final String? authToken;

  HttpServer? _server;
  AdbTracker? _tracker;

  final Map<String, DeviceSession> _sessions = {};
  final Set<WebSocket> _clients = {};

  String? _selectedDevice;
  String _statusText = 'starting';
  bool _isDisposed = false;

  Timer? _flushTimer;
  Timer? _pidTimer;

  Map<String, DeviceSession> get sessions => Map.unmodifiable(_sessions);
  String? get activeSerial => _activeSerial();
  List<AdbDeviceEntry> get devices => _tracker?.devices ?? const [];

  /// Attempts to bind to loopback (127.0.0.1) and start the bridge server.
  Future<bool> start() async {
    _isDisposed = false;
    try {
      // Phase 1.5.5: Explicitly bind to 127.0.0.1 (loopback only) for security
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (_) {
      return false;
    } catch (_) {
      return false;
    }

    _log('logcat bridge listening on http://127.0.0.1:$port');
    if (authToken != null && authToken!.isNotEmpty) {
      _log('Session auth token: $authToken');
    }
    if (webRoot != null) _log('serving web build from $webRoot');
    _log('adb: $adbPath');

    // Start push-based device tracker (Phase 1.5.4)
    _tracker = AdbTracker(
      adbPath: adbPath,
      processRunner: processRunner,
      onDevicesChanged: _onDevicesChanged,
      onError: (err) => _log('[tracker] $err'),
    );
    await _tracker!.start();

    // Start periodic background tasks
    _flushTimer = Timer.periodic(kFlushInterval, (_) => _flushAllSessions());
    _pidTimer = Timer.periodic(kPidPollInterval, (_) => _resolveActivePids());

    _listenServer();
    return true;
  }

  /// Validates the Origin header to prevent Cross-Site WebSocket Hijacking (CSWSH)
  /// and cross-origin attacks from malicious browser websites.
  bool _isValidOrigin(HttpRequest req) {
    final origin = req.headers.value('origin');
    // Non-browser clients (native desktop Flutter, curl, adb) omit the Origin header
    if (origin == null || origin.isEmpty) return true;
    try {
      final uri = Uri.parse(origin);
      final host = uri.host.toLowerCase();
      if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Checks authentication token when token authentication is enabled.
  bool _isAuthorized(HttpRequest req) {
    final token = authToken;
    if (token == null || token.isEmpty) return true;

    final queryToken = req.uri.queryParameters['token'];
    if (queryToken != null && queryToken == token) return true;

    final headerToken = req.headers.value('x-auth-token');
    if (headerToken != null && headerToken == token) return true;

    final authHeader = req.headers.value('authorization');
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      final bearerToken = authHeader.substring(7).trim();
      if (bearerToken == token) return true;
    }

    return false;
  }

  void _listenServer() async {
    final server = _server;
    if (server == null) return;

    try {
      await for (final req in server) {
        if (_isDisposed) break;

        // Origin check to prevent Cross-Site WebSocket Hijacking (CSWSH)
        if (!_isValidOrigin(req)) {
          req.response
            ..statusCode = HttpStatus.forbidden
            ..write('Forbidden: Invalid Origin');
          await req.response.close();
          continue;
        }

        // Static asset requests when serving a web bundle
        final isStaticAsset =
            webRoot != null &&
            (req.uri.path == '/' ||
                req.uri.path == '/index.html' ||
                req.uri.path.startsWith('/assets/') ||
                req.uri.path.endsWith('.js') ||
                req.uri.path.endsWith('.css') ||
                req.uri.path.endsWith('.wasm') ||
                req.uri.path.endsWith('.png') ||
                req.uri.path.endsWith('.svg') ||
                req.uri.path.endsWith('.json'));

        // Token authentication check
        if (!isStaticAsset && !_isAuthorized(req)) {
          req.response
            ..statusCode = HttpStatus.unauthorized
            ..write('Unauthorized: Missing or invalid authentication token');
          await req.response.close();
          continue;
        }

        if (req.uri.path == '/ws' &&
            WebSocketTransformer.isUpgradeRequest(req)) {
          final socket = await WebSocketTransformer.upgrade(req);
          _onClient(socket);
        } else if (req.uri.path == '/stream' &&
            WebSocketTransformer.isUpgradeRequest(req)) {
          await _handleStreamWs(req);
        } else if (req.uri.path == '/api/stream') {
          await _handleStreamMjpeg(req);
        } else if (req.uri.path == '/api/scrcpy/launch') {
          await _handleScrcpyLaunch(req);
        } else if (req.uri.path == '/api/scrcpy/status') {
          await _handleScrcpyStatus(req);
        } else if (req.uri.path == '/api/scrcpy/install') {
          await _handleScrcpyInstall(req);
        } else if (req.uri.path == '/api/input') {
          await _handleInput(req);
        } else if (req.uri.path == '/api/screenshot') {
          await _handleScreenshot(req);
        } else if (req.uri.path == '/api/record/start') {
          await _handleRecordStart(req);
        } else if (req.uri.path == '/api/record/stop') {
          await _handleRecordStop(req);
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
    _flushTimer?.cancel();
    _pidTimer?.cancel();

    await _tracker?.stop();
    _tracker = null;

    for (final session in _sessions.values) {
      try {
        await session.dispose();
      } catch (_) {}
    }
    _sessions.clear();

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
    onLog?.call(text);
  }

  // ---------------------------------------------------------------- Device management

  DeviceSession _getOrCreateSession(String serial) {
    if (!DeviceSession.isValidSerial(serial)) {
      throw ArgumentError('Invalid device serial format: $serial');
    }
    return _sessions.putIfAbsent(serial, () {
      final session = DeviceSession(
        serial: serial,
        adbPath: adbPath,
        processRunner: processRunner,
        onStatusChange: (status) {
          if (serial == _activeSerial()) {
            _statusText = status;
            _broadcastStatus();
          }
        },
        onSystemMessage: (msg) => _log(msg),
      );
      // Clean up any lingering screenrecord orphans on initialization
      unawaited(session.killOrphans());
      return session;
    });
  }

  void _onDevicesChanged(List<AdbDeviceEntry> currentDevices) async {
    if (_isDisposed) return;

    final currentSerials = currentDevices.map((d) => d.serial).toSet();

    // Clean up disconnected sessions
    final disconnectedSerials =
        _sessions.keys.where((s) => !currentSerials.contains(s)).toList();
    for (final s in disconnectedSerials) {
      final session = _sessions.remove(s);
      if (session != null) {
        _log('[bridge] Device disconnected: $s. Disposing session.');
        await session.dispose();
      }
    }

    final serial = _activeSerial();
    if (serial != null) {
      final session = _getOrCreateSession(serial);
      _statusText = session.status;
      if (session.status != 'connected') {
        unawaited(session.startLogcat());
      }
    } else {
      final unauthorized =
          currentDevices.where((d) => !d.isAuthorized).toList();
      if (unauthorized.isNotEmpty) {
        _statusText = 'unauthorized';
      } else {
        _statusText = 'no device';
      }
    }

    _broadcastStatus();
  }

  String? _activeSerial() {
    final devList = devices;
    final authorized = devList.where((d) => d.isAuthorized).toList();
    if (_selectedDevice != null &&
        authorized.any((d) => d.serial == _selectedDevice)) {
      return _selectedDevice;
    }
    return authorized.isEmpty ? null : authorized.first.serial;
  }

  Future<void> _resolveActivePids() async {
    final serial = _activeSerial();
    if (serial == null) return;
    final session = _sessions[serial];
    if (session != null) {
      await session.resolvePid();
      _broadcastStatus();
    }
  }

  void _flushAllSessions() {
    if (_clients.isEmpty) return;

    for (final entry in _sessions.entries) {
      final serial = entry.key;
      final session = entry.value;
      final batch = session.flushPending();
      if (batch.isNotEmpty) {
        _broadcast({'type': 'lines', 'serial': serial, 'lines': batch});
      }
    }
  }

  // ---------------------------------------------------------------- WebSocket clients

  void _onClient(WebSocket socket) {
    _clients.add(socket);

    // Send handshake and current status
    socket.add(
      jsonEncode({
        'type': 'handshake',
        'protocolVersion': kProtocolVersion,
        'serverVersion': '1.0.0',
      }),
    );

    final serial = _activeSerial();
    if (serial != null) {
      final session = _getOrCreateSession(serial);
      socket.add(
        jsonEncode({
          'type': 'history',
          'serial': serial,
          'lines': session.history,
        }),
      );
    }

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

    final targetSerial = (cmd['serial'] as String?)?.trim() ?? _activeSerial();
    if (targetSerial != null && !DeviceSession.isValidSerial(targetSerial)) {
      _log('[bridge] Command rejected: invalid serial format "$targetSerial"');
      return;
    }

    switch (cmd['cmd']) {
      case 'hello':
        final clientVersion =
            cmd['protocolVersion'] as int? ?? cmd['version'] as int? ?? 1;
        if (clientVersion != kProtocolVersion) {
          _log(
            '[bridge] Client version mismatch: client=$clientVersion, server=$kProtocolVersion',
          );
        }
        _broadcastStatus();
        break;

      case 'filter':
        final pkg = (cmd['package'] as String?)?.trim();
        if (targetSerial != null) {
          final session = _getOrCreateSession(targetSerial);
          session.setPackageFilter(pkg);
          await session.resolvePid();
        }
        _broadcastStatus();
        break;

      case 'clear':
        if (targetSerial != null) {
          final session = _getOrCreateSession(targetSerial);
          await session.clear();
        }
        _broadcast({
          'type': 'clear',
          if (targetSerial != null) 'serial': targetSerial,
        });
        break;

      case 'restart':
        if (targetSerial != null) {
          final session = _getOrCreateSession(targetSerial);
          await session.startLogcat();
        }
        break;

      case 'device':
        final serial = (cmd['serial'] as String?)?.trim();
        _selectedDevice = (serial == null || serial.isEmpty) ? null : serial;
        final newActive = _activeSerial();
        if (newActive != null) {
          final session = _getOrCreateSession(newActive);
          if (session.status != 'connected') {
            await session.startLogcat();
          }
          _broadcast({
            'type': 'history',
            'serial': newActive,
            'lines': session.history,
          });
        }
        _broadcastStatus();
        break;

      case 'scrcpy':
        if (targetSerial != null) {
          final session = _getOrCreateSession(targetSerial);
          await session.launchScrcpy();
        }
        break;

      case 'input':
        if (targetSerial != null) {
          final session = _getOrCreateSession(targetSerial);
          final action = cmd['action'] as String?;
          switch (action) {
            case 'tap':
              final x = (cmd['x'] as num?)?.toInt();
              final y = (cmd['y'] as num?)?.toInt();
              if (x != null && y != null) await session.sendInputTap(x, y);
              break;
            case 'swipe':
              final x1 = (cmd['x1'] as num?)?.toInt();
              final y1 = (cmd['y1'] as num?)?.toInt();
              final x2 = (cmd['x2'] as num?)?.toInt();
              final y2 = (cmd['y2'] as num?)?.toInt();
              final d = (cmd['durationMs'] as num?)?.toInt() ?? 300;
              if (x1 != null && y1 != null && x2 != null && y2 != null) {
                await session.sendInputSwipe(x1, y1, x2, y2, d);
              }
              break;
            case 'key':
              final keyCode = (cmd['keyCode'] as num?)?.toInt();
              if (keyCode != null) await session.sendInputKey(keyCode);
              break;
            case 'text':
              final text = cmd['text'] as String?;
              if (text != null) await session.sendInputText(text);
              break;
          }
        }
        break;
    }
  }

  Map<String, dynamic> _statusMessage() {
    final active = _activeSerial();
    final activeSession = active != null ? _sessions[active] : null;

    return {
      'type': 'status',
      'protocolVersion': kProtocolVersion,
      'status': activeSession?.status ?? _statusText,
      'package': activeSession?.packageFilter,
      'pid': activeSession?.appPid,
      'devices': devices.map((d) => d.toJson()).toList(),
      'device': active,
      if (active != null) 'serial': active,
      'isRecording': activeSession?.isRecording ?? false,
      'isStreaming': activeSession?.isStreaming ?? false,
    };
  }

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

  // ---------------------------------------------------------------- Screenshot & Recording

  Future<void> _handleScreenshot(HttpRequest req) async {
    final serial = req.uri.queryParameters['serial'] ?? _activeSerial();
    if (serial == null) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('No active device serial provided');
      await req.response.close();
      return;
    }
    if (!DeviceSession.isValidSerial(serial)) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid device serial format: $serial');
      await req.response.close();
      return;
    }

    try {
      final res = await processRunner.run(adbPath, [
        '-s',
        serial,
        'exec-out',
        'screencap',
        '-p',
      ], stdoutEncoding: null);
      if (res.exitCode != 0) {
        req.response
          ..statusCode = HttpStatus.internalServerError
          ..write('screencap failed with exit code ${res.exitCode}');
        await req.response.close();
        return;
      }

      req.response.headers.contentType = ContentType('image', 'png');
      req.response.add(res.stdout as List<int>);
      await req.response.close();
    } catch (e) {
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..write('screencap error: $e');
      await req.response.close();
    }
  }

  Future<void> _handleRecordStart(HttpRequest req) async {
    final serial = req.uri.queryParameters['serial'] ?? _activeSerial();
    if (serial == null) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('No active device serial provided');
      await req.response.close();
      return;
    }
    if (!DeviceSession.isValidSerial(serial)) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid device serial format: $serial');
      await req.response.close();
      return;
    }

    final session = _getOrCreateSession(serial);
    final bitRate =
        int.tryParse(req.uri.queryParameters['bitRate'] ?? '') ?? 6000000;
    final started = await session.startRecording(bitRate: bitRate);

    req.response.headers.contentType = ContentType.json;
    if (started) {
      req.response.write(
        jsonEncode({
          'status': 'recording',
          'serial': serial,
          'startedAt': session.recordingStartedAt?.toIso8601String(),
        }),
      );
    } else {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write(
        jsonEncode({
          'status': 'error',
          'message': 'Failed to start screenrecord process',
        }),
      );
    }
    await req.response.close();
    _broadcastStatus();
  }

  Future<void> _handleRecordStop(HttpRequest req) async {
    final serial = req.uri.queryParameters['serial'] ?? _activeSerial();
    if (serial == null) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('No active device serial provided');
      await req.response.close();
      return;
    }
    if (!DeviceSession.isValidSerial(serial)) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid device serial format: $serial');
      await req.response.close();
      return;
    }

    final session = _sessions[serial];
    if (session == null || !session.isRecording) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('No active recording session for device $serial');
      await req.response.close();
      return;
    }

    final bytes = await session.stopRecording();
    if (bytes != null) {
      final filename =
          'wcat_${serial}_${DateTime.now().millisecondsSinceEpoch}.mp4';
      req.response.headers.contentType = ContentType('video', 'mp4');
      req.response.headers.set(
        'Content-Disposition',
        'attachment; filename="$filename"',
      );
      req.response.add(bytes);
    } else {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write('Failed to pull or finalize MP4 recording');
    }
    await req.response.close();
    _broadcastStatus();
  }

  Future<void> _handleStreamWs(HttpRequest req) async {
    final serial = req.uri.queryParameters['serial'] ?? _activeSerial();
    final socket = await WebSocketTransformer.upgrade(req);
    if (serial == null || !DeviceSession.isValidSerial(serial)) {
      await socket.close(
        WebSocketStatus.protocolError,
        'Invalid or missing device serial provided',
      );
      return;
    }

    final session = _getOrCreateSession(serial);
    final fps = int.tryParse(req.uri.queryParameters['fps'] ?? '') ?? 15;
    final sub = session.streamFrames(fps: fps).listen((frame) {
      try {
        socket.add(frame);
      } catch (_) {}
    });

    unawaited(
      socket.done.whenComplete(() {
        sub.cancel();
      }),
    );
  }

  Future<void> _handleStreamMjpeg(HttpRequest req) async {
    final serial = req.uri.queryParameters['serial'] ?? _activeSerial();
    if (serial == null) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('No active device serial provided');
      await req.response.close();
      return;
    }
    if (!DeviceSession.isValidSerial(serial)) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid device serial format: $serial');
      await req.response.close();
      return;
    }

    final session = _getOrCreateSession(serial);
    final fps = int.tryParse(req.uri.queryParameters['fps'] ?? '') ?? 15;

    req.response.headers.set(
      'Content-Type',
      'multipart/x-mixed-replace; boundary=frame',
    );
    req.response.headers.set(
      'Cache-Control',
      'no-cache, no-store, must-revalidate',
    );
    req.response.headers.set('Connection', 'close');
    req.response.headers.set('Pragma', 'no-cache');

    final completer = Completer<void>();
    final sub = session
        .streamFrames(fps: fps)
        .listen(
          (frame) async {
            try {
              req.response.write('--frame\r\n');
              req.response.write('Content-Type: image/png\r\n');
              req.response.write('Content-Length: ${frame.length}\r\n\r\n');
              req.response.add(frame);
              req.response.write('\r\n');
              await req.response.flush();
            } catch (_) {
              if (!completer.isCompleted) completer.complete();
            }
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (_) {
            if (!completer.isCompleted) completer.complete();
          },
        );

    req.response.done.whenComplete(() {
      sub.cancel();
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future;
    await sub.cancel();
  }

  Future<void> _handleScrcpyLaunch(HttpRequest req) async {
    final serial = req.uri.queryParameters['serial'] ?? _activeSerial();
    if (serial == null) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('No active device serial provided');
      await req.response.close();
      return;
    }
    if (!DeviceSession.isValidSerial(serial)) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid device serial format: $serial');
      await req.response.close();
      return;
    }

    final session = _getOrCreateSession(serial);
    final result = await session.launchScrcpy();
    req.response.headers.contentType = ContentType.json;
    if (result['status'] == 'error') {
      req.response.statusCode = HttpStatus.internalServerError;
    }
    req.response.write(jsonEncode(result));
    await req.response.close();
  }

  Future<void> _handleScrcpyStatus(HttpRequest req) async {
    final path = ScrcpyResolver.findScrcpyExecutable();
    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode({
        'installed': path != null,
        'path': path,
        'version': ScrcpyResolver.version,
      }),
    );
    await req.response.close();
  }

  Future<void> _handleScrcpyInstall(HttpRequest req) async {
    final result = await ScrcpyResolver.installScrcpy(
      onStatus: (msg) => _log('[scrcpy install] $msg'),
    );
    req.response.headers.contentType = ContentType.json;
    if (result['status'] != 'ok') {
      req.response.statusCode = HttpStatus.internalServerError;
    }
    req.response.write(jsonEncode(result));
    await req.response.close();
  }

  Future<void> _handleInput(HttpRequest req) async {
    Map<String, dynamic> data = {};
    if (req.method == 'POST') {
      try {
        final content = await utf8.decoder.bind(req).join();
        if (content.isNotEmpty) {
          data = jsonDecode(content) as Map<String, dynamic>;
        }
      } catch (_) {}
    }

    final serial =
        data['serial']?.toString() ??
        req.uri.queryParameters['serial'] ??
        _activeSerial();
    if (serial == null) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('No active device serial provided');
      await req.response.close();
      return;
    }
    if (!DeviceSession.isValidSerial(serial)) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid device serial format: $serial');
      await req.response.close();
      return;
    }

    final session = _getOrCreateSession(serial);
    final action =
        data['action']?.toString() ?? req.uri.queryParameters['action'];
    bool success = false;

    switch (action) {
      case 'tap':
        final x =
            (data['x'] as num?)?.toInt() ??
            int.tryParse(req.uri.queryParameters['x'] ?? '');
        final y =
            (data['y'] as num?)?.toInt() ??
            int.tryParse(req.uri.queryParameters['y'] ?? '');
        if (x != null && y != null) {
          success = await session.sendInputTap(x, y);
        }
        break;
      case 'swipe':
        final x1 =
            (data['x1'] as num?)?.toInt() ??
            int.tryParse(req.uri.queryParameters['x1'] ?? '');
        final y1 =
            (data['y1'] as num?)?.toInt() ??
            int.tryParse(req.uri.queryParameters['y1'] ?? '');
        final x2 =
            (data['x2'] as num?)?.toInt() ??
            int.tryParse(req.uri.queryParameters['x2'] ?? '');
        final y2 =
            (data['y2'] as num?)?.toInt() ??
            int.tryParse(req.uri.queryParameters['y2'] ?? '');
        final duration =
            (data['durationMs'] as num?)?.toInt() ??
            int.tryParse(req.uri.queryParameters['durationMs'] ?? '') ??
            300;
        if (x1 != null && y1 != null && x2 != null && y2 != null) {
          success = await session.sendInputSwipe(x1, y1, x2, y2, duration);
        }
        break;
      case 'key':
        final keyCode =
            (data['keyCode'] as num?)?.toInt() ??
            int.tryParse(req.uri.queryParameters['keyCode'] ?? '');
        if (keyCode != null) {
          success = await session.sendInputKey(keyCode);
        }
        break;
      case 'text':
        final text =
            data['text']?.toString() ?? req.uri.queryParameters['text'];
        if (text != null) {
          success = await session.sendInputText(text);
        }
        break;
      default:
        req.response
          ..statusCode = HttpStatus.badRequest
          ..write('Invalid or missing input action: $action');
        await req.response.close();
        return;
    }

    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode({'status': success ? 'ok' : 'error', 'action': action}),
    );
    await req.response.close();
  }

  // ---------------------------------------------------------------- Static files

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
