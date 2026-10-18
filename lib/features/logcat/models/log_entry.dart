/// String canonicalization pool to reduce garbage collection churn on repeating tags and packages.
class StringPool {
  static final Map<String, String> _pool = {};
  static const int _maxSize = 1024;

  static String intern(String str) {
    if (str.length > 80) return str;
    final existing = _pool[str];
    if (existing != null) return existing;
    if (_pool.length < _maxSize) {
      _pool[str] = str;
    }
    return str;
  }
}

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

  factory LogEntry.fromJson(Map<String, dynamic> j) {
    final level = StringPool.intern(j['level'] as String? ?? 'V');
    final tag = StringPool.intern(j['tag'] as String? ?? '');
    final pkg = j['pkg'] != null ? StringPool.intern(j['pkg'] as String) : null;

    return LogEntry(
      seq: j['seq'] as int? ?? 0,
      time: j['time'] as String? ?? '',
      pid: j['pid'] as int? ?? 0,
      tid: j['tid'] as int? ?? 0,
      level: level,
      tag: tag,
      msg: j['msg'] as String? ?? '',
      pkg: pkg,
    );
  }

  /// Numerical rank of severity from 0 (Verbose) to 5 (Assert).
  int get rank => switch (level) {
    'V' => 0,
    'D' => 1,
    'I' => 2,
    'W' => 3,
    'E' => 4,
    'F' || 'S' => 5,
    _ => 0,
  };

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
}
