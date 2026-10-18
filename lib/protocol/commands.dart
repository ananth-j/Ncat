/// Base class for all outgoing commands sent to the bridge server.
sealed class BridgeCommand {
  const BridgeCommand();

  Map<String, dynamic> toJson();
}

/// Command to set an application package filter on the bridge.
class FilterCommand extends BridgeCommand {
  const FilterCommand(this.package);

  final String? package;

  @override
  Map<String, dynamic> toJson() => {
        'cmd': 'filter',
        'package': package,
      };
}

/// Command to clear the logcat buffer on the device and server.
class ClearCommand extends BridgeCommand {
  const ClearCommand();

  @override
  Map<String, dynamic> toJson() => {'cmd': 'clear'};
}

/// Command to restart the adb logcat process on the bridge.
class RestartCommand extends BridgeCommand {
  const RestartCommand();

  @override
  Map<String, dynamic> toJson() => {'cmd': 'restart'};
}

/// Command to select an active device serial on the bridge.
class DeviceCommand extends BridgeCommand {
  const DeviceCommand(this.serial);

  final String? serial;

  @override
  Map<String, dynamic> toJson() => {
        'cmd': 'device',
        'serial': serial ?? '',
      };
}
