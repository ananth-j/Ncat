import 'dart:async';
import 'bridge_server_io.dart';

LogcatBridgeServer? _embeddedServer;

Future<void> ensureBridgeRunning({int port = 8080}) async {
  if (_embeddedServer != null) return;

  final server = LogcatBridgeServer(
    port: port,
  );

  final started = await server.start();
  if (started) {
    _embeddedServer = server;
  }
}

Future<void> stopBridge() async {
  await _embeddedServer?.stop();
  _embeddedServer = null;
}
