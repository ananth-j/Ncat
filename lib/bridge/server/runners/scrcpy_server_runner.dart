import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'process_runner.dart';
import 'scrcpy_resolver.dart';

/// Manages the headless scrcpy-server running directly on an Android device.
/// Establishes forward tunnels over ADB for the video stream (H.264) and
/// bidirectional control socket (touch and key injection).
class ScrcpyServerRunner {
  ScrcpyServerRunner({
    required this.serial,
    required this.adbPath,
    this.processRunner = const RealProcessRunner(),
    this.onLog,
    this.onStatusChange,
  });

  final String serial;
  final String adbPath;
  final ProcessRunner processRunner;
  final void Function(String text)? onLog;
  final void Function(String status)? onStatusChange;

  Process? _serverProcess;
  Socket? _videoSocket;
  Socket? _controlSocket;
  int? _localPort;
  String? _socketName;
  bool _isRunning = false;
  bool _isDisposed = false;

  final StreamController<Uint8List> _videoStreamController =
      StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get videoStream => _videoStreamController.stream;
  bool get isRunning => _isRunning;
  int? get localPort => _localPort;
  String? get socketName => _socketName;

  void _log(String text) => onLog?.call('[scrcpy-server:$serial] $text');

  /// Finds an available ephemeral port on loopback IPv4.
  Future<int> _findAvailablePort() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    return port;
  }

  /// Pushes scrcpy-server.jar and initiates the headless server process on device.
  Future<Map<String, dynamic>> start({int maxFps = 60, int? maxSize}) async {
    if (_isDisposed) {
      return {'status': 'error', 'message': 'Runner is disposed'};
    }
    if (_isRunning) {
      return {'status': 'running', 'port': _localPort};
    }

    onStatusChange?.call('starting');

    // 1. Locate scrcpy-server jar on host
    final serverJar = ScrcpyResolver.findScrcpyServer();
    if (serverJar == null) {
      onStatusChange?.call('not_installed');
      return {
        'status': 'not_installed',
        'message':
            'scrcpy-server is not found. Please install scrcpy tools in Wcat.',
      };
    }

    try {
      // 2. Push scrcpy-server to Android device
      _log('Pushing $serverJar to /data/local/tmp/scrcpy-server.jar');
      final pushRes = await processRunner.run(adbPath, [
        '-s',
        serial,
        'push',
        serverJar,
        '/data/local/tmp/scrcpy-server.jar',
      ]);
      if (pushRes.exitCode != 0) {
        throw Exception('Failed to push scrcpy-server: ${pushRes.stderr}');
      }

      // 3. Set up ADB forward tunnel
      final port = await _findAvailablePort();
      _localPort = port;
      final scid = serial.hashCode.abs() % 0x7FFFFFFF;
      final socketName = 'scrcpy_${scid.toRadixString(16).padLeft(8, '0')}';
      _socketName = socketName;

      _log('Setting up ADB forward tcp:$port localabstract:$socketName');
      final fwdRes = await processRunner.run(adbPath, [
        '-s',
        serial,
        'forward',
        'tcp:$port',
        'localabstract:$socketName',
      ]);
      if (fwdRes.exitCode != 0) {
        throw Exception('ADB forward failed: ${fwdRes.stderr}');
      }

      // 4. Launch scrcpy-server via app_process
      final version = ScrcpyResolver.version.replaceFirst('v', '');
      final serverArgs = <String>[
        '-s',
        serial,
        'shell',
        'CLASSPATH=/data/local/tmp/scrcpy-server.jar',
        'app_process',
        '/',
        'com.genymobile.scrcpy.Server',
        version,
        'tunnel_forward=true',
        'control=true',
        'audio=false',
        'video=true',
        'raw_stream=true',
        'scid=$scid',
        'max_fps=$maxFps',
        if (maxSize != null) 'max_size=$maxSize',
      ];

      _log('Starting scrcpy-server with version $version');
      final p = await processRunner.start(adbPath, serverArgs);
      _serverProcess = p;

      p.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) => _log('[server] $line'));

      p.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) => _log('[server err] $line'));

      unawaited(
        p.exitCode.then((code) {
          if (_serverProcess == p) {
            _serverProcess = null;
            _log('Server process terminated ($code)');
            if (_isRunning) {
              unawaited(stop());
            }
          }
        }),
      );

      // 5. Connect Video and Control sockets with retry loop
      if (processRunner is RealProcessRunner) {
        const maxRetries = 25;
        Socket? video;
        Socket? control;

        for (int i = 0; i < maxRetries; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (_serverProcess == null) break;

          try {
            if (video == null) {
              video = await Socket.connect(InternetAddress.loopbackIPv4, port);
              _log('Connected to video socket');
            }
            if (control == null) {
              control = await Socket.connect(InternetAddress.loopbackIPv4, port);
              _log('Connected to control socket');
            }
            break;
          } catch (_) {
            // Socket not ready yet on device
          }
        }

        if (video == null || control == null) {
          video?.destroy();
          control?.destroy();
          throw Exception('Timed out waiting for scrcpy-server socket connections');
        }

        _videoSocket = video;
        _controlSocket = control;

        // Pipe video bytes into broadcast stream
        video.listen(
          (data) {
            if (!_videoStreamController.isClosed) {
              _videoStreamController.add(data);
            }
          },
          onError: (err) {
            _log('Video socket error: $err');
            unawaited(stop());
          },
          onDone: () {
            _log('Video socket closed');
            unawaited(stop());
          },
          cancelOnError: true,
        );

        control.listen(
          (data) {
            // Scrcpy device-to-client messages (e.g. clipboard)
          },
          onError: (err) => _log('Control socket error: $err'),
          onDone: () => _log('Control socket closed'),
          cancelOnError: true,
        );
      }

      _isRunning = true;
      onStatusChange?.call('running');
      return {
        'status': 'launched',
        'port': port,
        'serial': serial,
        'pid': p.pid,
      };
    } catch (e) {
      _log('Failed to start scrcpy-server: $e');
      await stop();
      onStatusChange?.call('error');
      return {'status': 'error', 'message': e.toString()};
    }
  }

  /// Sends a raw scrcpy binary control packet (e.g. inject touch or keycode).
  bool sendControlPacket(Uint8List packet) {
    final sock = _controlSocket;
    if (sock != null && _isRunning) {
      try {
        sock.add(packet);
        return true;
      } catch (e) {
        _log('Failed to send control packet: $e');
      }
    }
    return false;
  }

  /// Stops server, cleans up sockets and removes ADB forward.
  Future<void> stop() async {
    _isRunning = false;
    onStatusChange?.call('stopped');

    final video = _videoSocket;
    _videoSocket = null;
    if (video != null) {
      try {
        await video.close();
        video.destroy();
      } catch (_) {}
    }

    final control = _controlSocket;
    _controlSocket = null;
    if (control != null) {
      try {
        await control.close();
        control.destroy();
      } catch (_) {}
    }

    final p = _serverProcess;
    _serverProcess = null;
    if (p != null) {
      try {
        p.kill();
      } catch (_) {}
    }

    final port = _localPort;
    _localPort = null;
    if (port != null) {
      try {
        await processRunner.run(adbPath, [
          '-s',
          serial,
          'forward',
          '--remove',
          'tcp:$port',
        ]);
      } catch (_) {}
    }
  }

  /// Disposes this runner and closes the broadcast stream.
  Future<void> dispose() async {
    _isDisposed = true;
    await stop();
    await _videoStreamController.close();
  }
}
