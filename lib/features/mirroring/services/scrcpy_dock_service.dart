import 'dart:ui';

import 'scrcpy_dock_stub.dart'
    if (dart.library.io) 'scrcpy_dock_win32.dart';

/// Contract for docking and reparenting an external scrcpy window inside the Wcat UI.
abstract class ScrcpyDockService {
  factory ScrcpyDockService() => createDockService();

  /// Whether window docking is supported on the current host OS.
  bool get isSupported;

  /// Attempts to find the scrcpy window with [windowTitle] and reparent it into the host window.
  Future<bool> dock({
    required String windowTitle,
    required Rect bounds,
    required double devicePixelRatio,
  });

  /// Updates the child window position and size relative to the host window client area.
  void updateBounds({
    required Rect bounds,
    required double devicePixelRatio,
  });

  /// Undocks the window into an independent floating borderless/windowed desktop window.
  void undock();

  /// Closes the docked window and cleans up native resources.
  void close();
}
