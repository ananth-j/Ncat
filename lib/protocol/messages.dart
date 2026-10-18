import '../features/devices/models/device_info.dart';
import '../features/logcat/models/log_entry.dart';

const int kProtocolVersion = 1;

/// Base class for all incoming messages from the bridge server.
sealed class BridgeMessage {
  const BridgeMessage({this.serial});

  /// Device serial this message pertains to, if multiplexed or session-scoped.
  final String? serial;

  factory BridgeMessage.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    final serial = json['serial'] as String? ?? json['device'] as String?;

    switch (type) {
      case 'handshake':
        return HandshakeMessage(
          protocolVersion:
              json['protocolVersion'] as int? ?? json['version'] as int? ?? 1,
          serverVersion: json['serverVersion'] as String?,
          serial: serial,
        );
      case 'history':
        return HistoryMessage(
          (json['lines'] as List? ?? [])
              .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
              .toList(),
          serial: serial,
        );
      case 'lines':
        return LogBatchMessage(
          (json['lines'] as List? ?? [])
              .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
              .toList(),
          serial: serial,
        );
      case 'clear':
        return ClearMessage(serial: serial);
      case 'status':
        return StatusMessage(
          status: json['status'] as String? ?? '',
          package: json['package'] as String?,
          pid: json['pid'] as int?,
          devices:
              (json['devices'] as List? ?? [])
                  .map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>))
                  .toList(),
          activeDevice: json['device'] as String? ?? serial,
          protocolVersion: json['protocolVersion'] as int? ?? kProtocolVersion,
          isRecording: json['isRecording'] as bool? ?? false,
          isStreaming: json['isStreaming'] as bool? ?? false,
          serial: serial,
        );
      default:
        return UnknownMessage(json, serial: serial);
    }
  }
}

class HandshakeMessage extends BridgeMessage {
  const HandshakeMessage({
    required this.protocolVersion,
    this.serverVersion,
    super.serial,
  });

  final int protocolVersion;
  final String? serverVersion;
}

class HistoryMessage extends BridgeMessage {
  const HistoryMessage(this.lines, {super.serial});
  final List<LogEntry> lines;
}

class LogBatchMessage extends BridgeMessage {
  const LogBatchMessage(this.lines, {super.serial});
  final List<LogEntry> lines;
}

class ClearMessage extends BridgeMessage {
  const ClearMessage({super.serial});
}

class StatusMessage extends BridgeMessage {
  const StatusMessage({
    required this.status,
    this.package,
    this.pid,
    required this.devices,
    this.activeDevice,
    this.protocolVersion = kProtocolVersion,
    this.isRecording = false,
    this.isStreaming = false,
    super.serial,
  });

  final String status;
  final String? package;
  final int? pid;
  final List<DeviceInfo> devices;
  final String? activeDevice;
  final int protocolVersion;
  final bool isRecording;
  final bool isStreaming;
}

class UnknownMessage extends BridgeMessage {
  const UnknownMessage(this.raw, {super.serial});
  final Map<String, dynamic> raw;
}
