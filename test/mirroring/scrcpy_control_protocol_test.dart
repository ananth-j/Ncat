import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/features/mirroring/services/scrcpy_control_protocol.dart';

void main() {
  group('ScrcpyControlProtocol', () {
    test('encodeTouchEvent creates valid 32-byte packet', () {
      final packet = ScrcpyControlProtocol.encodeTouchEvent(
        action: ScrcpyControlProtocol.actionDown,
        x: 500,
        y: 1000,
        screenWidth: 1080,
        screenHeight: 2400,
      );

      expect(packet.length, 32);
      final byteData = ByteData.sublistView(packet);
      // Type is 2
      expect(byteData.getUint8(0), ScrcpyControlProtocol.typeInjectTouchEvent);
      // Action is 0 (DOWN)
      expect(byteData.getUint8(1), ScrcpyControlProtocol.actionDown);
      // Pointer ID is -1
      expect(byteData.getInt64(2, Endian.big), -1);
      // X is 500
      expect(byteData.getUint32(10, Endian.big), 500);
      // Y is 1000
      expect(byteData.getUint32(14, Endian.big), 1000);
      // Width is 1080
      expect(byteData.getUint16(18, Endian.big), 1080);
      // Height is 2400
      expect(byteData.getUint16(20, Endian.big), 2400);
    });

    test('encodeKeycodeEvent creates valid 14-byte packet', () {
      final packet = ScrcpyControlProtocol.encodeKeycodeEvent(
        action: ScrcpyControlProtocol.keyActionDown,
        keyCode: 4, // KEYCODE_BACK
      );

      expect(packet.length, 14);
      final byteData = ByteData.sublistView(packet);
      // Type is 0
      expect(byteData.getUint8(0), ScrcpyControlProtocol.typeInjectKeycode);
      // Action is 0 (DOWN)
      expect(byteData.getUint8(1), ScrcpyControlProtocol.keyActionDown);
      // Keycode is 4
      expect(byteData.getUint32(2, Endian.big), 4);
      // Repeat is 0
      expect(byteData.getUint32(6, Endian.big), 0);
      // MetaState is 0
      expect(byteData.getUint32(10, Endian.big), 0);
    });

    test('createTapPackets returns down and up packets', () {
      final packets = ScrcpyControlProtocol.createTapPackets(
        x: 100,
        y: 200,
        screenWidth: 1080,
        screenHeight: 1920,
      );

      expect(packets.length, 2);
      expect(packets[0][1], ScrcpyControlProtocol.actionDown);
      expect(packets[1][1], ScrcpyControlProtocol.actionUp);
    });

    test('createKeyPressPackets returns down and up packets', () {
      final packets = ScrcpyControlProtocol.createKeyPressPackets(3); // HOME

      expect(packets.length, 2);
      expect(packets[0][1], ScrcpyControlProtocol.keyActionDown);
      expect(packets[1][1], ScrcpyControlProtocol.keyActionUp);
    });
  });
}
