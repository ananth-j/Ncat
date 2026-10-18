import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/protocol/commands.dart';
import 'package:wcat/protocol/messages.dart';

void main() {
  group('Protocol Versioning & Multiplexing (T.8)', () {
    test(
      'Handshake message correctly decodes protocolVersion and serverVersion',
      () {
        final msg = BridgeMessage.fromJson({
          'type': 'handshake',
          'protocolVersion': 1,
          'serverVersion': '1.0.0',
          'serial': 'emu-1',
        });

        expect(msg, isA<HandshakeMessage>());
        final handshake = msg as HandshakeMessage;
        expect(handshake.protocolVersion, 1);
        expect(handshake.serverVersion, '1.0.0');
        expect(handshake.serial, 'emu-1');
      },
    );

    test(
      'StatusMessage includes protocolVersion and serial for multiplexing',
      () {
        final msg = BridgeMessage.fromJson({
          'type': 'status',
          'status': 'connected',
          'protocolVersion': 1,
          'serial': 'device-abc',
          'devices': [],
        });

        expect(msg, isA<StatusMessage>());
        final status = msg as StatusMessage;
        expect(status.protocolVersion, 1);
        expect(status.serial, 'device-abc');
        expect(status.status, 'connected');
      },
    );

    test('LogBatchMessage and HistoryMessage propagate device serial', () {
      final batchMsg = BridgeMessage.fromJson({
        'type': 'lines',
        'serial': 'serial-123',
        'lines': [
          {
            'seq': 1,
            'time': '10-18 10:00:00.000',
            'pid': 1,
            'tid': 1,
            'level': 'I',
            'tag': 'Test',
            'msg': 'Log line',
          },
        ],
      });

      expect(batchMsg, isA<LogBatchMessage>());
      expect(batchMsg.serial, 'serial-123');
      expect((batchMsg as LogBatchMessage).lines.length, 1);

      final clearMsg = BridgeMessage.fromJson({
        'type': 'clear',
        'serial': 'serial-123',
      });
      expect(clearMsg, isA<ClearMessage>());
      expect(clearMsg.serial, 'serial-123');
    });

    test('HelloCommand serializes protocolVersion and clientInfo', () {
      const hello = HelloCommand(
        protocolVersion: 1,
        clientInfo: 'wcat-web-client',
        serial: 'device-xyz',
      );

      final json = hello.toJson();
      expect(json['cmd'], 'hello');
      expect(json['protocolVersion'], 1);
      expect(json['client'], 'wcat-web-client');
      expect(json['serial'], 'device-xyz');
    });

    test('Commands preserve serial field for target device routing', () {
      const filter = FilterCommand('com.app.test', serial: 'dev-1');
      expect(filter.toJson(), {
        'cmd': 'filter',
        'package': 'com.app.test',
        'serial': 'dev-1',
      });

      const clear = ClearCommand(serial: 'dev-2');
      expect(clear.toJson(), {'cmd': 'clear', 'serial': 'dev-2'});

      const restart = RestartCommand(serial: 'dev-3');
      expect(restart.toJson(), {'cmd': 'restart', 'serial': 'dev-3'});
    });
  });
}
