import 'dart:typed_data';

/// Implements the binary wire protocol for Scrcpy control sockets.
/// Translates UI gestures and keyboard inputs into standard scrcpy binary control packets.
class ScrcpyControlProtocol {
  // Scrcpy Control Message Types
  static const int typeInjectKeycode = 0;
  static const int typeInjectText = 1;
  static const int typeInjectTouchEvent = 2;
  static const int typeInjectScrollEvent = 3;
  static const int typeBackOrScreenOn = 4;
  static const int typeExpandNotificationPanel = 5;
  static const int typeCollapseNotificationPanel = 6;
  static const int typeGetClipboard = 7;
  static const int typeSetClipboard = 8;
  static const int typeSetScreenPowerMode = 9;
  static const int typeRotateDevice = 10;

  // Android MotionEvent actions
  static const int actionDown = 0;
  static const int actionUp = 1;
  static const int actionMove = 2;
  static const int actionCancel = 3;

  // Android KeyEvent actions
  static const int keyActionDown = 0;
  static const int keyActionUp = 1;

  // Android MotionEvent buttons
  static const int buttonPrimary = 1;

  /// Encodes an inject touch event into a 32-byte scrcpy control message.
  ///
  /// Byte layout:
  /// - 0..0: uint8 type (2)
  /// - 1..1: uint8 action (0=DOWN, 1=UP, 2=MOVE)
  /// - 2..9: int64 pointerId (-1 for mouse/single touch)
  /// - 10..13: uint32 positionX
  /// - 14..17: uint32 positionY
  /// - 18..19: uint16 screenWidth
  /// - 20..21: uint16 screenHeight
  /// - 22..25: float32 pressure (1.0f)
  /// - 26..29: uint32 actionButton (1 = primary)
  /// - 30..33: uint32 buttonsState (1 = primary)
  static Uint8List encodeTouchEvent({
    required int action,
    required int x,
    required int y,
    required int screenWidth,
    required int screenHeight,
    int pointerId = -1,
    double pressure = 1.0,
  }) {
    final data = ByteData(32);
    data.setUint8(0, typeInjectTouchEvent);
    data.setUint8(1, action);
    data.setInt64(2, pointerId, Endian.big);
    data.setUint32(10, x.clamp(0, screenWidth), Endian.big);
    data.setUint32(14, y.clamp(0, screenHeight), Endian.big);
    data.setUint16(18, screenWidth, Endian.big);
    data.setUint16(20, screenHeight, Endian.big);
    // Pressure represented as 16-bit fixed point: 1.0f -> 0xFFFF
    final u16Pressure = (pressure.clamp(0.0, 1.0) * 0xFFFF).toInt();
    data.setUint16(22, u16Pressure, Endian.big);
    data.setUint32(24, buttonPrimary, Endian.big);
    data.setUint32(28, buttonPrimary, Endian.big);
    return data.buffer.asUint8List();
  }

  /// Encodes an inject keycode into a 14-byte scrcpy control message.
  ///
  /// Byte layout:
  /// - 0..0: uint8 type (0)
  /// - 1..1: uint8 action (0=DOWN, 1=UP)
  /// - 2..5: uint32 keycode
  /// - 6..9: uint32 repeat (0)
  /// - 10..13: uint32 metaState (0)
  static Uint8List encodeKeycodeEvent({
    required int action,
    required int keyCode,
    int repeat = 0,
    int metaState = 0,
  }) {
    final data = ByteData(14);
    data.setUint8(0, typeInjectKeycode);
    data.setUint8(1, action);
    data.setUint32(2, keyCode, Endian.big);
    data.setUint32(6, repeat, Endian.big);
    data.setUint32(10, metaState, Endian.big);
    return data.buffer.asUint8List();
  }

  /// Creates a pair of Down and Up touch packets representing an instantaneous tap.
  static List<Uint8List> createTapPackets({
    required int x,
    required int y,
    required int screenWidth,
    required int screenHeight,
  }) {
    return [
      encodeTouchEvent(
        action: actionDown,
        x: x,
        y: y,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
      ),
      encodeTouchEvent(
        action: actionUp,
        x: x,
        y: y,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
      ),
    ];
  }

  /// Creates a pair of Down and Up key packets representing an instantaneous key press.
  static List<Uint8List> createKeyPressPackets(int keyCode) {
    return [
      encodeKeycodeEvent(action: keyActionDown, keyCode: keyCode),
      encodeKeycodeEvent(action: keyActionUp, keyCode: keyCode),
    ];
  }
}
