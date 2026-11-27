import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'runners/process_runner.dart';
import 'runners/scrcpy_resolver.dart';

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
  static final RegExp _wsRe = RegExp(r'\s+');

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
  Process? _scrcpyProcess;
  Process? _recordProcess;
  Process? _inputShellProcess;
  IOSink? _inputStdin;

  String? _packageFilter;
  int? _appPid;
  int _seq = 0;
  String _statusText = 'starting';
  bool _isDisposed = false;

  final List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _pending = [];
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
  bool get isDisposed => _isDisposed;

  void setPackageFilter(String? pkg) {
    _packageFilter = (pkg == null || pkg.trim().isEmpty) ? null : pkg.trim();
    _appPid = null;
  }

  /// Flushes pending log entries, appending to history and returning the batch.
  List<Map<String, dynamic>> flushPending() {
    if (_pending.isEmpty) return const [];
    final batch = _pending;
    _pending = [];
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
          final cols = l.trim().split(_wsRe);
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
          (r.stdout as String).trim().split(_wsRe).first,
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
        '/sdcard/thruwire_*.mp4',
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

  /// True when the recording is being done via scrcpy instead of screenrecord.
  bool _usingScrcpyRecord = false;

  /// Local MP4 path when scrcpy --record is used (output goes directly to host).
  String? _scrcpyLocalRecordPath;
  String? _recordingStartError;

  DateTime? get recordingStartedAt => _recordingStartedAt;
  String? get recordingStartError => _recordingStartError;

  /// Starts screen recording. First tries the native Android [screenrecord] command.
  /// If the process crashes within 2 seconds (common on Realme/OPPO Android 14 devices
  /// where the screenrecord binary segfaults), automatically retries using
  /// [scrcpy --no-display --record], which uses a different capture path.
  Future<bool> startRecording({int bitRate = 6000000}) async {
    if (_isDisposed || _recordProcess != null) return false;

    _recordingStartError = null;

    await killOrphans();

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final sanitizedSerial = serial.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

    // --- Attempt 1: native screenrecord on device ---
    final remotePath = '/sdcard/thruwire_${sanitizedSerial}_$timestamp.mp4';
    _currentRecordingDevicePath = remotePath;
    _usingScrcpyRecord = false;
    _scrcpyLocalRecordPath = null;

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

      // Give the process 1.5 s to prove it's alive (segfaulting processes exit instantly)
      final exitCode = await _processExitCodeWithin(
        p,
        const Duration(milliseconds: 1500),
      );

      if (exitCode == null) {
        _recordProcess = p;
        _recordingStartedAt = DateTime.now();
        _system('Recording started via screenrecord ($remotePath)');

        // Handle the 3-minute hard limit of Android screenrecord (180s)
        _recordLimitTimer?.cancel();
        _recordLimitTimer = Timer(const Duration(seconds: 175), () {
          _system('Recording approaching 3-minute limit (175s elapsed)');
        });

        unawaited(
          p.exitCode.then((code) {
            if (_recordProcess == p) _recordProcess = null;
            _recordLimitTimer?.cancel();
          }),
        );
        return true;
      }

      // screenrecord crashed early — try to kill it cleanly
      try { p.kill(); } catch (_) {}
      _recordingStartError = 'Android screenrecord exited with code $exitCode.';
      _system('screenrecord exited with code $exitCode — retrying with scrcpy --record');
    } catch (e) {
      _recordingStartError = 'Could not launch Android screenrecord: $e';
      _system('screenrecord failed to start: $e — retrying with scrcpy --record');
    }

    // Clean up stale remote file from the failed attempt
    _currentRecordingDevicePath = null;
    try {
      await processRunner.run(adbPath, ['-s', serial, 'shell', 'rm', '-f', remotePath]);
    } catch (_) {}

    // --- Attempt 2: scrcpy --no-display --record (bypasses screenrecord binary) ---
    return _startScrcpyRecord(sanitizedSerial, timestamp, bitRate);
  }

  /// Falls back to recording via [scrcpy --no-display --record].
  /// The MP4 is written directly to the host's temp directory.
  Future<bool> _startScrcpyRecord(
    String sanitizedSerial,
    int timestamp,
    int bitRate,
  ) async {
    final scrcpyExe = ScrcpyResolver.findScrcpyExecutable();
    if (scrcpyExe == null) {
      _recordingStartError = '${_recordingStartError ?? 'Android screenrecord failed.'} '
          'scrcpy is not installed; install it from the mirror pane to enable the fallback.';
      _system(_recordingStartError!);
      return false;
    }

    final localPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'thruwire_${sanitizedSerial}_$timestamp.mp4';

    try {
      final p = await processRunner.start(scrcpyExe, [
        '-s',
        serial,
        '--no-display',
        '--record',
        localPath,
        '--video-bit-rate',
        '${(bitRate / 1000000).round()}M',
      ]);

      // scrcpy takes ~1 s to initialise; wait up to 3 s for it to stabilise
      final exitCode = await _processExitCodeWithin(p, const Duration(seconds: 3));
      if (exitCode != null) {
        try { p.kill(); } catch (_) {}
        _recordingStartError = 'scrcpy exited with code $exitCode while starting.';
        _system(_recordingStartError!);
        return false;
      }

      _recordProcess = p;
      _recordingStartedAt = DateTime.now();
      _usingScrcpyRecord = true;
      _scrcpyLocalRecordPath = localPath;
      _system('Recording started via scrcpy --record ($localPath)');

      unawaited(
        p.exitCode.then((code) {
          if (_recordProcess == p) _recordProcess = null;
          _recordLimitTimer?.cancel();
        }),
      );
      return true;
    } catch (e) {
      _recordingStartError = 'Could not launch scrcpy recording: $e';
      _system('scrcpy --record failed: $e');
      return false;
    }
  }

  /// Waits up to [timeout] for [process] to exit.
  /// Returns true if it exited (crashed), false if it is still running.
  Future<int?> _processExitCodeWithin(Process process, Duration timeout) async {
    try {
      return await process.exitCode.timeout(timeout);
    } on TimeoutException {
      return null; // still running → good
    }
  }

  /// Stops screen recording, finalises the MP4, pulls it to the host (for the
  /// native screenrecord path), and returns the raw MP4 bytes.
  Future<List<int>?> stopRecording() async {
    final p = _recordProcess;
    final remotePath = _currentRecordingDevicePath;
    final localPath = _scrcpyLocalRecordPath;
    final usingScrcpy = _usingScrcpyRecord;

    _recordLimitTimer?.cancel();
    _recordingStartedAt = null;
    _usingScrcpyRecord = false;
    _scrcpyLocalRecordPath = null;

    if (usingScrcpy) {
      // scrcpy records directly to [localPath] on the host.
      // Kill scrcpy gracefully so it finalises the MP4 moov atom.
      if (p != null) {
        try { p.kill(ProcessSignal.sigint); } catch (_) {
          try { p.kill(); } catch (_) {}
        }
        try {
          await p.exitCode.timeout(const Duration(seconds: 8));
        } catch (_) {
          try { p.kill(); } catch (_) {}
        }
      }
      _recordProcess = null;
      _currentRecordingDevicePath = null;

      if (localPath == null) return null;

      // Give scrcpy a moment to flush and close the file
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final file = File(localPath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        try { await file.delete(); } catch (_) {}
        _system('Recording finalised via scrcpy (${bytes.length} bytes)');
        return bytes;
      }
      _system('scrcpy recording file not found at $localPath');
      return null;
    }

    // --- native screenrecord path ---
    if (remotePath == null) return null;

    try {
      // 1. Send SIGINT on the device to gracefully terminate screenrecord
      //    so the MP4 moov atom is properly written.
      //    If pkill is not permitted, kill the adb shell process directly.
      final pkillResult = await processRunner.run(adbPath, [
        '-s', serial, 'shell', 'pkill', '-2', 'screenrecord',
      ]);

      if (pkillResult.exitCode != 0) {
        // pkill not permitted on this device — kill via the adb shell process
        try { p?.kill(ProcessSignal.sigint); } catch (_) {
          try { p?.kill(); } catch (_) {}
        }
      }

      // 2. Wait for the process to exit (up to 6 s)
      if (p != null) {
        try {
          await p.exitCode.timeout(const Duration(seconds: 6));
        } catch (_) {
          p.kill();
        }
      }
      _recordProcess = null;

      // Small delay to ensure Android filesystem syncs the file before pull
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 3. Pull MP4 to a local temp file
      final localTemp =
          '${Directory.systemTemp.path}/thruwire_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final pullResult = await processRunner.run(adbPath, [
        '-s', serial, 'pull', remotePath, localTemp,
      ]);

      // 4. Delete the temp file from the device regardless of pull outcome
      await processRunner.run(adbPath, [
        '-s', serial, 'shell', 'rm', '-f', remotePath,
      ]);
      _currentRecordingDevicePath = null;

      if (pullResult.exitCode != 0) {
        _system('Failed to pull recording from device: ${pullResult.stderr}');
        return null;
      }

      final file = File(localTemp);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        try { await file.delete(); } catch (_) {}
        _system('Recording successfully pulled and finalised (${bytes.length} bytes)');
        return bytes;
      }
    } catch (e) {
      _system('Error stopping recording: $e');
    }
    return null;
  }

  /// Takes an instant screenshot from the device.
  ///
  /// On Windows, [adb exec-out] corrupts binary data with CRLF translation,
  /// so we fall back to writing to a temp file on the device and pulling it.
  Future<Uint8List?> takeScreenshot() async {
    if (_isDisposed) return null;

    // Try exec-out first (fast path, works on macOS/Linux and most Windows builds)
    try {
      final res = await processRunner.run(adbPath, [
        '-s',
        serial,
        'exec-out',
        'screencap',
        '-p',
      ], stdoutEncoding: null);
      if (res.exitCode == 0 && res.stdout is List<int>) {
        final bytes = Uint8List.fromList(res.stdout as List<int>);
        // Validate PNG magic bytes (137 P N G \r \n 26 \n)
        if (_isPng(bytes)) return bytes;
      }
    } catch (_) {}

    // Fallback: write PNG to /sdcard/tmp, pull, delete (safe on Windows exec-out)
    final sanitizedSerial = serial.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final remotePath =
        '/sdcard/thruwire_sc_${sanitizedSerial}_${DateTime.now().millisecondsSinceEpoch}.png';
    try {
      final captureResult = await processRunner.run(adbPath, [
        '-s',
        serial,
        'shell',
        'screencap',
        '-p',
        remotePath,
      ]);
      if (captureResult.exitCode != 0) return null;

      final localTemp =
          '${Directory.systemTemp.path}/thruwire_sc_${DateTime.now().millisecondsSinceEpoch}.png';
      final pullResult = await processRunner.run(adbPath, [
        '-s',
        serial,
        'pull',
        remotePath,
        localTemp,
      ]);

      // Always clean up the remote temp file
      await processRunner.run(adbPath, [
        '-s',
        serial,
        'shell',
        'rm',
        '-f',
        remotePath,
      ]);

      if (pullResult.exitCode != 0) return null;

      final file = File(localTemp);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        try {
          await file.delete();
        } catch (_) {}
        if (_isPng(bytes)) return bytes;
      }
    } catch (e) {
      _system('Screenshot fallback failed: $e');
    }
    return null;
  }

  /// Returns true if [bytes] starts with the PNG magic signature.
  static bool _isPng(Uint8List bytes) =>
      bytes.length > 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 && // P
      bytes[2] == 0x4E && // N
      bytes[3] == 0x47;   // G

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

  /// Sends a tap event to the device at (x, y) using persistent shell stdin.
  Future<bool> sendInputTap(int x, int y) async {
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
  ]) async {
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

  /// Launches an external scrcpy window for this device serial with zero host CPU cost.
  Future<Map<String, dynamic>> launchScrcpy() async {
    if (_isDisposed) {
      return {'status': 'error', 'message': 'Device session disposed'};
    }

    final existingProcess = _scrcpyProcess;
    if (existingProcess != null) {
      return {
        'status': 'launched',
        'serial': serial,
        'pid': existingProcess.pid,
      };
    }

    final executable = ScrcpyResolver.findScrcpyExecutable();
    if (executable == null) {
      return {
        'status': 'not_installed',
        'message':
            'scrcpy is not installed on this system. You can install it automatically in ThruWire.',
      };
    }

    try {
      final p = await processRunner.start(executable, [
        '-s',
        serial,
        '--window-title',
        'ThruWire mirror - $serial',
      ]);
      _scrcpyProcess = p;
      unawaited(
        p.exitCode.then((_) {
          if (_scrcpyProcess == p) _scrcpyProcess = null;
        }),
      );
      _system(
        'Launched scrcpy window for $serial (PID ${p.pid}) using $executable',
      );
      return {'status': 'launched', 'serial': serial, 'pid': p.pid};
    } catch (e) {
      return {
        'status': 'error',
        'message': 'Failed to launch scrcpy ($executable): $e',
      };
    }
  }

  Future<bool> stopScrcpy() async {
    final process = _scrcpyProcess;
    if (process == null) return false;
    _scrcpyProcess = null;
    try {
      return process.kill();
    } catch (_) {
      return false;
    }
  }

  /// Disposes this session, terminating all associated processes.
  Future<void> dispose() async {
    _isDisposed = true;
    _recordLimitTimer?.cancel();
    await stopLogcat();
    await stopScrcpy();

    final inputP = _inputShellProcess;
    _inputShellProcess = null;
    _inputStdin = null;
    if (inputP != null) {
      try {
        inputP.kill();
      } catch (_) {}
    }

    final recordP = _recordProcess;
    _recordProcess = null;
    if (recordP != null) {
      try {
        recordP.kill();
      } catch (_) {}
    }

    await killOrphans();
  }
}
