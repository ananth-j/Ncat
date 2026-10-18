import '../features/devices/models/device_info.dart';
import '../features/logcat/models/log_entry.dart';

/// Base class for all incoming messages from the bridge server.
sealed class BridgeMessage {
  const BridgeMessage();

  factory BridgeMessage.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'history':
        return HistoryMessage(
          (json['lines'] as List? ?? [])
              .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      case 'lines':
        return LogBatchMessage(
          (json['lines'] as List? ?? [])
              .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      case 'clear':
        return const ClearMessage();
      case 'status':
        return StatusMessage(
          status: json['status'] as String? ?? '',
          package: json['package'] as String?,
          pid: json['pid'] as int?,
          devices: (json['devices'] as List? ?? [])
              .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
              .toList(),
          activeDevice: json['device'] as String?,
        );
      default:
        return UnknownMessage(json);
    }
  }
}

class HistoryMessage extends BridgeMessage {
  const HistoryMessage(this.lines);
  final List<LogEntry> lines;
}

class LogBatchMessage extends BridgeMessage {
  const LogBatchMessage(this.lines);
  final List<LogEntry> lines;
}

class ClearMessage extends BridgeMessage {
  const ClearMessage();
}

class StatusMessage extends BridgeMessage {
  const StatusMessage({
    required this.status,
    this.package,
    this.pid,
    required this.devices,
    this.activeDevice,
  });

  final String status;
  final String? package;
  final int? pid;
  final List<DeviceInfo> devices;
  final String? activeDevice;
}

class UnknownMessage extends BridgeMessage {
  const UnknownMessage(this.raw);
  final Map<String, dynamic> raw;
}
