import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/protocol/commands.dart';
import 'package:wcat/protocol/messages.dart';

void main() {
  group('BridgeMessage protocol decoding', () {
    test('parses history message', () {
      final msg = BridgeMessage.fromJson({
        'type': 'history',
        'lines': [
          {
            'seq': 1,
            'time': '10-04 12:00:00.000',
            'pid': 100,
            'tid': 101,
            'level': 'D',
            'tag': 'TestTag',
            'msg': 'History item',
          }
        ],
      });

      expect(msg, isA<HistoryMessage>());
      final history = msg as HistoryMessage;
      expect(history.lines.length, 1);
      expect(history.lines.first.tag, 'TestTag');
    });

    test('parses lines batch message', () {
      final msg = BridgeMessage.fromJson({
        'type': 'lines',
        'lines': [
          {
            'seq': 2,
            'time': '10-04 12:00:01.000',
            'pid': 200,
            'tid': 201,
            'level': 'E',
            'tag': 'ErrTag',
            'msg': 'Something failed',
          }
        ],
      });

      expect(msg, isA<LogBatchMessage>());
      final batch = msg as LogBatchMessage;
      expect(batch.lines.length, 1);
      expect(batch.lines.first.level, 'E');
    });

    test('parses clear message', () {
      final msg = BridgeMessage.fromJson({'type': 'clear'});
      expect(msg, isA<ClearMessage>());
    });

    test('parses status message with devices', () {
      final msg = BridgeMessage.fromJson({
        'type': 'status',
        'status': 'streaming',
        'package': 'com.example.app',
        'pid': 4321,
        'devices': [
          {'serial': 'DEVICE1', 'model': 'Pixel 7', 'authorized': true},
        ],
        'device': 'DEVICE1',
      });

      expect(msg, isA<StatusMessage>());
      final status = msg as StatusMessage;
      expect(status.status, 'streaming');
      expect(status.package, 'com.example.app');
      expect(status.pid, 4321);
      expect(status.devices.length, 1);
      expect(status.devices.first.serial, 'DEVICE1');
      expect(status.activeDevice, 'DEVICE1');
    });
  });

  group('BridgeCommand serialization', () {
    test('FilterCommand toJson matches protocol specification', () {
      const cmd = FilterCommand('com.example.test');
      expect(cmd.toJson(), {'cmd': 'filter', 'package': 'com.example.test'});
    });

    test('ClearCommand toJson matches protocol specification', () {
      const cmd = ClearCommand();
      expect(cmd.toJson(), {'cmd': 'clear'});
    });

    test('RestartCommand toJson matches protocol specification', () {
      const cmd = RestartCommand();
      expect(cmd.toJson(), {'cmd': 'restart'});
    });

    test('DeviceCommand toJson matches protocol specification', () {
      const cmd = DeviceCommand('DEVICE_XYZ');
      expect(cmd.toJson(), {'cmd': 'device', 'serial': 'DEVICE_XYZ'});
    });
  });
}
