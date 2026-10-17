// A tiny logcat bridge: spawns `adb logcat`, parses each line, and streams
// batches of structured entries to any connected WebSocket client.
//
//   dart run bin/server.dart
//   dart run bin/server.dart --port 8080 --web ../web/build/web

import 'dart:io';
import 'package:logoi/src/bridge_server_io.dart';

Future<void> main(List<String> args) async {
  final port = int.tryParse(_argValue(args, '--port') ?? '') ?? 8080;
  final webRoot = _argValue(args, '--web');
  final adb = Platform.environment['ADB'] ?? findAdbPath();

  final server = LogcatBridgeServer(
    port: port,
    webRoot: webRoot,
    adbPath: adb,
    onLog: stdout.writeln,
  );

  final started = await server.start();
  if (!started) {
    stderr.writeln('Error: Failed to bind to port $port (address already in use).');
    exit(1);
  }

  if (!Platform.isWindows) {
    ProcessSignal.sigint.watch().listen((_) async {
      await server.stop();
      exit(0);
    });
  }
}

String? _argValue(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}
