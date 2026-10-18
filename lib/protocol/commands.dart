import 'messages.dart';

/// Base class for all outgoing commands sent to the bridge server.
sealed class BridgeCommand {
  const BridgeCommand({this.serial});

  /// Optional device serial target for this command.
  final String? serial;

  Map<String, dynamic> toJson();
}

/// Command to initialize the handshake and verify protocol version compatibility.
class HelloCommand extends BridgeCommand {
  const HelloCommand({
    this.protocolVersion = kProtocolVersion,
    this.clientInfo,
    super.serial,
  });

  final int protocolVersion;
  final String? clientInfo;

  @override
  Map<String, dynamic> toJson() => {
    'cmd': 'hello',
    'protocolVersion': protocolVersion,
    if (clientInfo != null) 'client': clientInfo,
    if (serial != null) 'serial': serial,
  };
}

/// Command to set an application package filter on the bridge.
class FilterCommand extends BridgeCommand {
  const FilterCommand(this.package, {super.serial});

  final String? package;

  @override
  Map<String, dynamic> toJson() => {
    'cmd': 'filter',
    'package': package,
    if (serial != null) 'serial': serial,
  };
}

/// Command to clear the logcat buffer on the device and server.
class ClearCommand extends BridgeCommand {
  const ClearCommand({super.serial});

  @override
  Map<String, dynamic> toJson() => {
    'cmd': 'clear',
    if (serial != null) 'serial': serial,
  };
}

/// Command to restart the adb logcat process on the bridge.
class RestartCommand extends BridgeCommand {
  const RestartCommand({super.serial});

  @override
  Map<String, dynamic> toJson() => {
    'cmd': 'restart',
    if (serial != null) 'serial': serial,
  };
}

/// Command to select an active device serial on the bridge.
class DeviceCommand extends BridgeCommand {
  const DeviceCommand(this.targetSerial, {super.serial});

  final String? targetSerial;

  @override
  Map<String, dynamic> toJson() => {
    'cmd': 'device',
    'serial': targetSerial ?? '',
  };
}

/// Command to launch external scrcpy window.
class ScrcpyCommand extends BridgeCommand {
  const ScrcpyCommand({super.serial});

  @override
  Map<String, dynamic> toJson() => {
    'cmd': 'scrcpy',
    if (serial != null) 'serial': serial,
  };
}

/// Command to send interactive touch/key input to the device.
class InputCommand extends BridgeCommand {
  const InputCommand.tap({required this.x, required this.y, super.serial})
    : action = 'tap',
      x1 = null,
      y1 = null,
      x2 = null,
      y2 = null,
      durationMs = null,
      keyCode = null,
      text = null;

  const InputCommand.swipe({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.durationMs = 300,
    super.serial,
  }) : action = 'swipe',
       x = null,
       y = null,
       keyCode = null,
       text = null;

  const InputCommand.key({required this.keyCode, super.serial})
    : action = 'key',
      x = null,
      y = null,
      x1 = null,
      y1 = null,
      x2 = null,
      y2 = null,
      durationMs = null,
      text = null;

  const InputCommand.text({required this.text, super.serial})
    : action = 'text',
      x = null,
      y = null,
      x1 = null,
      y1 = null,
      x2 = null,
      y2 = null,
      durationMs = null,
      keyCode = null;

  final String action;
  final int? x;
  final int? y;
  final int? x1;
  final int? y1;
  final int? x2;
  final int? y2;
  final int? durationMs;
  final int? keyCode;
  final String? text;

  @override
  Map<String, dynamic> toJson() => {
    'cmd': 'input',
    'action': action,
    if (serial != null) 'serial': serial,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (x1 != null) 'x1': x1,
    if (y1 != null) 'y1': y1,
    if (x2 != null) 'x2': x2,
    if (y2 != null) 'y2': y2,
    if (durationMs != null) 'durationMs': durationMs,
    if (keyCode != null) 'keyCode': keyCode,
    if (text != null) 'text': text,
  };
}
