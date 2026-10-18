/// Representation of an attached Android device or emulator.
class DeviceInfo {
  const DeviceInfo({required this.serial, this.model, this.authorized = true});

  final String serial;
  final String? model;
  final bool authorized;

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
    serial: j['serial'] as String,
    model: j['model'] as String?,
    authorized: j['authorized'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'serial': serial,
    'model': model,
    'authorized': authorized,
  };

  String get label {
    if (!authorized) return '$serial [Unauthorized]';
    return model == null ? serial : '$model ($serial)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceInfo &&
          runtimeType == other.runtimeType &&
          serial == other.serial &&
          model == other.model &&
          authorized == other.authorized;

  @override
  int get hashCode => serial.hashCode ^ model.hashCode ^ authorized.hashCode;
}
