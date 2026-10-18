import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Abstraction over platform process execution to enable deterministic,
/// hardware-free unit testing of bridge operations.
abstract interface class ProcessRunner {
  /// Runs a process synchronously to completion, returning a [ProcessResult].
  ///
  /// Arguments must always be passed as discrete argument lists, never shell strings.
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  });

  /// Starts a process asynchronously and returns a [Process] handle.
  ///
  /// Arguments must always be passed as discrete argument lists, never shell strings.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  });
}

/// Standard production implementation delegating to [dart:io.Process].
class RealProcessRunner implements ProcessRunner {
  const RealProcessRunner();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) {
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
  }
}

/// Recorded command invocation for verification in tests.
class ProcessCall {
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  ProcessCall(this.executable, this.arguments, {this.workingDirectory});

  @override
  String toString() => '$executable ${arguments.join(' ')}';
}

/// Fake process implementation for mocking [Process.start] in unit tests.
class FakeProcess implements Process {
  FakeProcess({
    int pid = 1234,
    int exitCode = 0,
    Stream<List<int>>? stdoutStream,
    Stream<List<int>>? stderrStream,
    IOSink? stdinSink,
    void Function(String text)? onInput,
    void Function(ProcessSignal signal)? onKill,
  }) : _pid = pid,
       _exitCodeCompleter = Completer<int>(),
       _stdout = stdoutStream ?? const Stream.empty(),
       _stderr = stderrStream ?? const Stream.empty(),
       _stdin = stdinSink ?? _DummyIOSink(onWrite: onInput),
       _onKill = onKill {
    if (exitCode != 0) {
      _exitCodeCompleter.complete(exitCode);
    }
  }

  final int _pid;
  final Completer<int> _exitCodeCompleter;
  final Stream<List<int>> _stdout;
  final Stream<List<int>> _stderr;
  final IOSink _stdin;
  final void Function(ProcessSignal signal)? _onKill;

  bool isKilled = false;
  ProcessSignal? lastSignal;

  @override
  int get pid => _pid;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  Stream<List<int>> get stderr => _stderr;

  @override
  IOSink get stdin => _stdin;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    isKilled = true;
    lastSignal = signal;
    _onKill?.call(signal);
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(1);
    }
    return true;
  }

  void completeExit(int code) {
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(code);
    }
  }
}

class _DummyIOSink implements IOSink {
  _DummyIOSink({this.onWrite});

  final void Function(String text)? onWrite;
  final StreamController<List<int>> _controller =
      StreamController<List<int>>.broadcast();

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => _controller.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _controller.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      _controller.addStream(stream);

  @override
  Future<void> close() => _controller.close();

  @override
  Future<void> get done => _controller.done;

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) {
    final str = object.toString();
    add(encoding.encode(str));
    onWrite?.call(str);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    write(objects.join(separator));
  }

  @override
  void writeCharCode(int charCode) {
    write(String.fromCharCode(charCode));
  }

  @override
  void writeln([Object? object = '']) {
    write('$object\n');
  }
}

/// Test fake process runner allowing deterministic responses without spawning real processes.
class FakeProcessRunner implements ProcessRunner {
  final List<ProcessCall> calls = [];
  final Map<String, Future<ProcessResult> Function(List<String> args)>
  _runHandlers = {};
  final Map<String, Future<Process> Function(List<String> args)>
  _startHandlers = {};

  Future<ProcessResult> Function(String executable, List<String> args)?
  defaultRunHandler;
  Future<Process> Function(String executable, List<String> args)?
  defaultStartHandler;

  void onRun(
    String commandPattern,
    Future<ProcessResult> Function(List<String> args) handler,
  ) {
    _runHandlers[commandPattern] = handler;
  }

  void onStart(
    String commandPattern,
    Future<Process> Function(List<String> args) handler,
  ) {
    _startHandlers[commandPattern] = handler;
  }

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) async {
    calls.add(
      ProcessCall(executable, arguments, workingDirectory: workingDirectory),
    );

    final fullCmd = '$executable ${arguments.join(' ')}';
    for (final entry in _runHandlers.entries) {
      if (fullCmd.contains(entry.key)) {
        return entry.value(arguments);
      }
    }

    if (defaultRunHandler != null) {
      return defaultRunHandler!(executable, arguments);
    }

    return ProcessResult(1234, 0, '', '');
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    calls.add(
      ProcessCall(executable, arguments, workingDirectory: workingDirectory),
    );

    final fullCmd = '$executable ${arguments.join(' ')}';
    for (final entry in _startHandlers.entries) {
      if (fullCmd.contains(entry.key)) {
        return entry.value(arguments);
      }
    }

    if (defaultStartHandler != null) {
      return defaultStartHandler!(executable, arguments);
    }

    return FakeProcess();
  }
}
