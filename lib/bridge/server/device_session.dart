import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../features/mirroring/services/scrcpy_control_protocol.dart';
import 'runners/process_runner.dart';
import 'runners/scrcpy_server_runner.dart';

const int kHistorySize = 3000;

/// Manages all processes, streams, and log history isolated to a single device.
class DeviceSession {
  DeviceSession({
    required this.serial,
    required this.adbPath,
    this.processRunner = const RealProcessRunner(),
    this.onStatusChange,
    this.onSystemMessage,
    this.onNewEntry,
  }) {
    if (!isValidSerial(serial)) {
      throw ArgumentError('Invalid device serial format: $serial');
    }
  }

  static final RegExp serialRegex = RegExp(r'^[a-zA-Z0-9._:-]{1,64}$');

  /// Validates that a device serial matches safe alphanumeric / identifier patterns
  /// and does not start with flags like '-'.
  static bool isValidSerial(String serial) =>
      serialRegex.hasMatch(serial) && !serial.startsWith('-');

  final String serial;
  final String adbPath;
  final ProcessRunner processRunner;

  final void Function(String status)? onStatusChange;
  final void Function(String text)? onSystemMessage;
  final void Function(Map<String, dynamic> entry)? onNewEntry;

  Process? _logcatProcess;
  Process? _streamProcess;
  Process? _recordProcess;
  Process? _inputShellProcess;
  IOSink? _inputStdin;
  int _activeStreamCount = 0;

  String? _packageFilter;
  int? _appPid;
  int _seq = 0;
  String _statusText = 'starting';
  bool _isDisposed = false;

  final List<Map<String, dynamic>> _history = [];
  final List<Map<String, dynamic>> _pending = [];
  final Map<int, String> _pidToProcess = {};
  int _psTicks = 0;

  final RegExp _logRe = RegExp(
    r'^(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEFS])\s+(.*?)\s*: ?(.*)$',
  );

  // Getters
  String get status => _statusText;
  String? get packageFilter => _packageFilter;
  int? get appPid => _appPid;
  List<Map<String, dynamic>> get history => List.unmodifiable(_history);
  bool get isRecording => _recordProcess != null;
  bool get isStreaming => _streamProcess != null || _activeStreamCount > 0;
  bool get isDisposed => _isDisposed;

  void setPackageFilter(String? pkg) {
    _packageFilter = (pkg == null || pkg.trim().isEmpty) ? null : pkg.trim();
    _appPid = null;
  }

  /// Flushes pending log entries, appending to history and returning the batch.
  List<Map<String, dynamic>> flushPending() {
    if (_pending.isEmpty) return const [];
    final batch = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();

    _history.addAll(batch);
    if (_history.length > kHistorySize) {
      _history.removeRange(0, _history.length - kHistorySize);
    }
    return batch;
  }

  /// Clears log history and resets pending queue.
  Future<void> clear() async {
    _history.clear();
    _pending.clear();
    try {
      await processRunner.run(adbPath, ['-s', serial, 'logcat', '-c']);
    } catch (_) {}
  }

  /// Starts the logcat streaming process for this device.
  Future<void> startLogcat() async {
    if (_isDisposed) return;
    await stopLogcat();

    try {
      await processRunner.run(adbPath, ['-s', serial, 'logcat', '-c']);
    } catch (_) {}

    if (_isDisposed) return;

    try {
      final p = await processRunner.start(adbPath, [
        '-s',
        serial,
        'logcat',
        '-v',
        'threadtime',
      ]);
      _logcatProcess = p;
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

      unawaited(
        p.exitCode.then((code) {
          if (_logcatProcess == p) {
            _logcatProcess = null;
          }
          if (!_isDisposed) {
            _setStatus('disconnected');
            _system('logcat exited ($code)');
          }
        }),
      );
    } catch (e) {
      _setStatus('adb error');
      _system('Could not start logcat on $serial: $e');
    }
  }

  /// Stops the logcat process.
  Future<void> stopLogcat() async {
    final p = _logcatProcess;
    _logcatProcess = null;
    if (p != null) {
      try {
        p.kill();
      } catch (_) {}
    }
  }

  /// Resolves the PID for the active package filter using `ps -A` and `pidof`.
  Future<void> resolvePid() async {
    if (_isDisposed) return;

    _psTicks++;
    if (_psTicks % 3 == 0 || (_packageFilter != null && _appPid == null)) {
      try {
        final r = await processRunner.run(adbPath, [
          '-s',
          serial,
          'shell',
          'ps',
          '-A',
        ]);
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
        final r = await processRunner.run(adbPath, [
          '-s',
          serial,
          'shell',
          'pidof',
          '-s',
          pkg,
        ]);
        pid = int.tryParse(
          (r.stdout as String).trim().split(RegExp(r'\s+')).first,
        );
      } catch (_) {}
    }

    if (pid != _appPid) {
      _appPid = pid;
      _system(pid == null ? '$pkg is not running' : '$pkg → pid $pid');
    }
  }

  /// Kills any orphaned `screenrecord` process running on device and deletes temp files.
  Future<void> killOrphans() async {
    try {
      // Send SIGINT / kill to any lingering screenrecord process on the Android device
      await processRunner.run(adbPath, [
        '-s',
        serial,
        'shell',
        'pkill',
        '-2',
        'screenrecord',
      ]);
    } catch (_) {}

    try {
      // Remove any leftover temp recordings in /sdcard/
      await processRunner.run(adbPath, [
        '-s',
        serial,
        'shell',
        'rm',
        '-f',
        '/sdcard/wcat_*.mp4',
      ]);
    } catch (_) {}
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;

    final m = _logRe.firstMatch(line);
    if (m == null) {
      final entry = _createEntry('', 0, 0, 'V', '--', line);
      _pending.add(entry);
      onNewEntry?.call(entry);
      return;
    }

    final pid = int.parse(m.group(2)!);
    if (_packageFilter != null && pid != _appPid) return;

    final entry = _createEntry(
      m.group(1)!,
      pid,
      int.parse(m.group(3)!),
      m.group(4)!,
      m.group(5)!,
      m.group(6)!,
    );
    _pending.add(entry);
    onNewEntry?.call(entry);
  }

  Map<String, dynamic> _createEntry(
    String time,
    int pid,
    int tid,
    String level,
    String tag,
    String msg,
  ) {
    final pkg =
        _pidToProcess[pid] ??
        (_packageFilter != null && pid == _appPid ? _packageFilter : null);
    return {
      'seq': _seq++,
      'time': time,
      'pid': pid,
      'tid': tid,
      'level': level,
      'tag': tag,
      'msg': msg,
      'serial': serial,
      if (pkg != null) 'pkg': pkg,
    };
  }

  void _system(String text) {
    onSystemMessage?.call('[device:$serial] $text');
    final entry = _createEntry('', 0, 0, 'I', 'bridge', text);
    _pending.add(entry);
    onNewEntry?.call(entry);
  }

  void _setStatus(String s) {
    _statusText = s;
    onStatusChange?.call(s);
  }

  String? _currentRecordingDevicePath;
  DateTime? _recordingStartedAt;
  Timer? _recordLimitTimer;

  DateTime? get recordingStartedAt => _recordingStartedAt;

  /// Starts native screen recording on the device without host-side transcoding.
  Future<bool> startRecording({int bitRate = 6000000}) async {
    if (_isDisposed || _recordProcess != null) return false;

    await killOrphans();

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sanitizedSerial = serial.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final remotePath = '/sdcard/wcat_${sanitizedSerial}_$timestamp.mp4';
    _currentRecordingDevicePath = remotePath;
    _recordingStartedAt = DateTime.now();

    try {
      final p = await processRunner.start(adbPath, [
        '-s',
        serial,
        'shell',
        'screenrecord',
        '--bit-rate',
        bitRate.toString(),
        remotePath,
      ]);
      _recordProcess = p;
      _system('Recording started ($remotePath)');

      // Handle the 3-minute hard limit of Android screenrecord (180s)
      _recordLimitTimer?.cancel();
      _recordLimitTimer = Timer(const Duration(seconds: 175), () {
        _system('Recording approaching 3-minute limit (175s elapsed)');
      });

      unawaited(
        p.exitCode.then((code) {
          if (_recordProcess == p) {
            _recordProcess = null;
          }
          _recordLimitTimer?.cancel();
        }),
      );

      return true;
    } catch (e) {
      _system('Failed to start recording: $e');
      _currentRecordingDevicePath = null;
      _recordingStartedAt = null;
      return false;
    }
  }

  /// Stops screen recording by sending SIGINT on the device, waits for exit so the MP4 moov
  /// atom is properly finalized, pulls the file to the host, and cleans up remote temp files.
  Future<List<int>?> stopRecording() async {
    final p = _recordProcess;
    final remotePath = _currentRecordingDevicePath;
    _recordLimitTimer?.cancel();
    _recordingStartedAt = null;

    if (remotePath == null) return null;

    try {
      // 1. Send SIGINT on the device to gracefully terminate screenrecord so MP4 header is written
      await processRunner.run(adbPath, [
        '-s',
        serial,
        'shell',
        'pkill',
        '-2',
        'screenrecord',
      ]);

      // 2. Wait for process exit with 6 second timeout
      if (p != null) {
        try {
          await p.exitCode.timeout(const Duration(seconds: 6));
        } catch (_) {
          p.kill();
        }
      }
      _recordProcess = null;

      // Small delay to ensure Android filesystem syncs file before pull
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 3. Pull file to local temp
      final localTemp =
          '${Directory.systemTemp.path}/wcat_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final pullResult = await processRunner.run(adbPath, [
        '-s',
        serial,
        'pull',
        remotePath,
        localTemp,
      ]);

      // 4. Delete temp file on Android device
      await processRunner.run(adbPath, [
        '-s',
        serial,
        'shell',
        'rm',
        '-f',
        remotePath,
      ]);
      _currentRecordingDevicePath = null;

      if (pullResult.exitCode != 0) {
        _system('Failed to pull recording from device: ${pullResult.stderr}');
        return null;
      }

      final file = File(localTemp);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        try {
          await file.delete();
        } catch (_) {}
        _system(
          'Recording successfully pulled and finalized (${bytes.length} bytes)',
        );
        return bytes;
      }
    } catch (e) {
      _system('Error stopping recording: $e');
    }
    return null;
  }

  /// Takes an instant screenshot from the device using adb exec-out screencap -p.
  Future<Uint8List?> takeScreenshot() async {
    if (_isDisposed) return null;
    try {
      final res = await processRunner.run(adbPath, [
        '-s',
        serial,
        'exec-out',
        'screencap',
        '-p',
      ], stdoutEncoding: null);
      if (res.exitCode == 0 && res.stdout is List<int>) {
        return Uint8List.fromList(res.stdout as List<int>);
      }
    } catch (_) {}
    return null;
  }

  /// Returns a broadcast Stream of frame bytes (PNG) captured at [fps] (1-30).
  /// Spawns the capture loop on first subscriber and terminates it when all subscribers cancel.
  Stream<Uint8List> streamFrames({int fps = 15}) {
    late StreamController<Uint8List> controller;
    Timer? frameTimer;
    bool isCapturing = false;

    final targetFps = fps.clamp(1, 30);
    final interval = Duration(milliseconds: 1000 ~/ targetFps);

    controller = StreamController<Uint8List>(
      onListen: () {
        _activeStreamCount++;
        frameTimer = Timer.periodic(interval, (_) async {
          if (isCapturing || _isDisposed || controller.isClosed) return;
          isCapturing = true;
          try {
            final bytes = await takeScreenshot();
            if (bytes != null && !controller.isClosed) {
              controller.add(bytes);
            }
          } finally {
            isCapturing = false;
          }
        });
      },
      onCancel: () {
        _activeStreamCount = (_activeStreamCount - 1).clamp(0, 999);
        frameTimer?.cancel();
        frameTimer = null;
      },
    );

    return controller.stream;
  }

  Future<void> _ensureInputShell() async {
    if (_isDisposed) return;
    if (_inputShellProcess == null) {
      try {
        final p = await processRunner.start(adbPath, ['-s', serial, 'shell']);
        _inputShellProcess = p;
        _inputStdin = p.stdin;
        unawaited(
          p.exitCode.then((_) {
            if (_inputShellProcess == p) {
              _inputShellProcess = null;
              _inputStdin = null;
            }
          }),
        );
      } catch (e) {
        _system('Failed to start input shell: $e');
      }
    }
  }

  /// Sends a tap event to the device at (x, y) using scrcpy control socket if running,
  /// falling back to persistent shell stdin.
  Future<bool> sendInputTap(int x, int y, {int screenWidth = 1080, int screenHeight = 2400}) async {
    final runner = _scrcpyRunner;
    if (runner != null && runner.isRunning) {
      final packets = ScrcpyControlProtocol.createTapPackets(
        x: x,
        y: y,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
      );
      for (final p in packets) {
        runner.sendControlPacket(p);
      }
      return true;
    }

    await _ensureInputShell();
    final stdin = _inputStdin;
    if (stdin != null) {
      stdin.writeln('input tap $x $y');
      await stdin.flush();
      return true;
    }
    return false;
  }

  /// Sends a swipe/drag event from (x1, y1) to (x2, y2) over [durationMs].
  Future<bool> sendInputSwipe(
    int x1,
    int y1,
    int x2,
    int y2, [
    int durationMs = 300,
    int screenWidth = 1080,
    int screenHeight = 2400,
  ]) async {
    final runner = _scrcpyRunner;
    if (runner != null && runner.isRunning) {
      runner.sendControlPacket(
        ScrcpyControlProtocol.encodeTouchEvent(
          action: ScrcpyControlProtocol.actionDown,
          x: x1,
          y: y1,
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        ),
      );
      await Future<void>.delayed(Duration(milliseconds: durationMs ~/ 2));
      runner.sendControlPacket(
        ScrcpyControlProtocol.encodeTouchEvent(
          action: ScrcpyControlProtocol.actionMove,
          x: x2,
          y: y2,
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        ),
      );
      await Future<void>.delayed(Duration(milliseconds: durationMs ~/ 2));
      runner.sendControlPacket(
        ScrcpyControlProtocol.encodeTouchEvent(
          action: ScrcpyControlProtocol.actionUp,
          x: x2,
          y: y2,
          screenWidth: screenWidth,
          screenHeight: screenHeight,
        ),
      );
      return true;
    }

    await _ensureInputShell();
    final stdin = _inputStdin;
    if (stdin != null) {
      stdin.writeln('input swipe $x1 $y1 $x2 $y2 $durationMs');
      await stdin.flush();
      return true;
    }
    return false;
  }

  /// Sends an Android keycode (e.g. 4 for Back, 3 for Home, 187 for App Switcher).
  Future<bool> sendInputKey(int keyCode) async {
    final runner = _scrcpyRunner;
    if (runner != null && runner.isRunning) {
      final packets = ScrcpyControlProtocol.createKeyPressPackets(keyCode);
      for (final p in packets) {
        runner.sendControlPacket(p);
      }
      return true;
    }

    await _ensureInputShell();
    final stdin = _inputStdin;
    if (stdin != null) {
      stdin.writeln('input keyevent $keyCode');
      await stdin.flush();
      return true;
    }
    return false;
  }

  /// Sends raw text input to the active focused field with sanitization
  /// against shell injection.
  Future<bool> sendInputText(String text) async {
    // Strip control characters (including CR, LF, null bytes) to prevent command injection
    final cleaned = text.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    if (cleaned.isEmpty) return false;

    await _ensureInputShell();
    final stdin = _inputStdin;
    if (stdin != null) {
      // Encode spaces as %s for Android input command
      final spaceEncoded = cleaned.replaceAll(' ', '%s');
      // POSIX shell escape: wrap in single quotes and replace ' with '\''
      final escaped = spaceEncoded.replaceAll("'", r"'\''");
      stdin.writeln("input text '$escaped'");
      await stdin.flush();
      return true;
    }
    return false;
  }

  ScrcpyServerRunner? _scrcpyRunner;

  /// Returns the raw H.264 video stream from headless scrcpy-server.
  Stream<Uint8List> get scrcpyVideoStream =>
      _scrcpyRunner?.videoStream ?? const Stream.empty();

  /// Whether the headless scrcpy-server is actively running on device.
  bool get isScrcpyRunning => _scrcpyRunner?.isRunning ?? false;

  /// Starts the headless scrcpy-server process on the device for embedded stream decoding.
  Future<Map<String, dynamic>> launchScrcpy({
    int maxFps = 60,
    int? maxSize,
    bool borderless = true,
    String? customTitle,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    if (_isDisposed) {
      return {'status': 'error', 'message': 'Device session disposed'};
    }

    await stopScrcpy();

    final runner = ScrcpyServerRunner(
      serial: serial,
      adbPath: adbPath,
      processRunner: processRunner,
      onLog: (msg) => _system(msg),
    );
    _scrcpyRunner = runner;

    final res = await runner.start(maxFps: maxFps, maxSize: maxSize);
    return res;
  }

  /// Stops any running headless scrcpy-server session for this device.
  Future<bool> stopScrcpy() async {
    final runner = _scrcpyRunner;
    _scrcpyRunner = null;
    if (runner != null) {
      await runner.stop();
      await runner.dispose();
      _system('Stopped scrcpy-server for $serial');
      return true;
    }
    return false;
  }

  /// Disposes this session, terminating all associated processes.
  Future<void> dispose() async {
    _isDisposed = true;
    _recordLimitTimer?.cancel();
    await stopLogcat();

    final inputP = _inputShellProcess;
    _inputShellProcess = null;
    _inputStdin = null;
    if (inputP != null) {
      try {
        inputP.kill();
      } catch (_) {}
    }

    final streamP = _streamProcess;
    _streamProcess = null;
    if (streamP != null) {
      try {
        streamP.kill();
      } catch (_) {}
    }

    final recordP = _recordProcess;
    _recordProcess = null;
    if (recordP != null) {
      try {
        recordP.kill();
      } catch (_) {}
    }

    await stopScrcpy();
    await killOrphans();
  }
}
