import 'dart:ui';

import 'scrcpy_dock_service.dart';

ScrcpyDockService createDockService() => ScrcpyDockStub();

/// No-op stub for platforms that do not support Win32 window reparenting (e.g. Web).
class ScrcpyDockStub implements ScrcpyDockService {
  @override
  bool get isSupported => false;

  @override
  Future<bool> dock({
    required String windowTitle,
    required Rect bounds,
    required double devicePixelRatio,
  }) async => false;

  @override
  void updateBounds({
    required Rect bounds,
    required double devicePixelRatio,
  }) {}

  @override
  void undock() {}

  @override
  void close() {}
}
