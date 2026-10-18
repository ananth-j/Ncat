import '../../../core/constants.dart';

/// Representation of a parsed logcat line received from the bridge server.
class LogEntry {
  const LogEntry({
    required this.seq,
    required this.time,
    required this.pid,
    required this.tid,
    required this.level,
    required this.tag,
    required this.msg,
    this.pkg,
  });

  final int seq;
  final String time;
  final int pid;
  final int tid;
  final String level;
  final String tag;
  final String msg;
  final String? pkg;

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        seq: j['seq'] as int,
        time: j['time'] as String,
        pid: j['pid'] as int,
        tid: j['tid'] as int,
        level: j['level'] as String,
        tag: j['tag'] as String,
        msg: j['msg'] as String,
        pkg: j['pkg'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'time': time,
        'pid': pid,
        'tid': tid,
        'level': level,
        'tag': tag,
        'msg': msg,
        if (pkg != null) 'pkg': pkg,
      };

  /// Numerical rank of severity from 0 (Verbose) to 5 (Assert).
  int get rank => kLevels.indexOf(level).clamp(0, kLevels.length - 1);
}
