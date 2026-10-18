import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui';
import 'package:ffi/ffi.dart';

import 'scrcpy_dock_service.dart';
import 'scrcpy_dock_stub.dart';

ScrcpyDockService createDockService() {
  if (Platform.isWindows) {
    return ScrcpyDockWin32();
  }
  return ScrcpyDockStub();
}

// Win32 Structs & Constants
final class _POINT extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

const int _gwlpHwndParent = -8;
const int _gwlStyle = -16;

const int _wsPopup = 0x80000000;
const int _wsCaption = 0x00C00000;
const int _wsThickFrame = 0x00040000;
const int _wsMinimizeBox = 0x00020000;
const int _wsMaximizeBox = 0x00010000;
const int _wsSysMenu = 0x00080000;
const int _wsVisible = 0x10000000;

const int _hwndTop = 0;
const int _swpNoActivate = 0x0010;
const int _swpFrameChanged = 0x0020;
const int _swpShowWindow = 0x0040;

const int _wmClose = 0x0010;

// Win32 FFI Signatures
typedef _FindWindowWC = IntPtr Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);
typedef _FindWindowWDart = int Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);

typedef _GetForegroundWindowC = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

typedef _GetActiveWindowC = IntPtr Function();
typedef _GetActiveWindowDart = int Function();

typedef _ClientToScreenC = Int32 Function(IntPtr hWnd, Pointer<_POINT> lpPoint);
typedef _ClientToScreenDart = int Function(int hWnd, Pointer<_POINT> lpPoint);

typedef _GetWindowLongPtrWC = IntPtr Function(IntPtr hWnd, Int32 nIndex);
typedef _GetWindowLongPtrWDart = int Function(int hWnd, int nIndex);

typedef _SetWindowLongPtrWC = IntPtr Function(
  IntPtr hWnd,
  Int32 nIndex,
  IntPtr dwNewLong,
);
typedef _SetWindowLongPtrWDart = int Function(
  int hWnd,
  int nIndex,
  int dwNewLong,
);

typedef _SetWindowPosC = Int32 Function(
  IntPtr hWnd,
  IntPtr hWndInsertAfter,
  Int32 X,
  Int32 Y,
  Int32 cx,
  Int32 cy,
  Uint32 uFlags,
);
typedef _SetWindowPosDart = int Function(
  int hWnd,
  int hWndInsertAfter,
  int X,
  int Y,
  int cx,
  int cy,
  int uFlags,
);

typedef _PostMessageWC = Int32 Function(
  IntPtr hWnd,
  Uint32 msg,
  IntPtr wParam,
  IntPtr lParam,
);
typedef _PostMessageWDart = int Function(
  int hWnd,
  int msg,
  int wParam,
  int lParam,
);

/// Windows native implementation of seamless borderless window docking and owner binding.
class ScrcpyDockWin32 implements ScrcpyDockService {
  ScrcpyDockWin32() {
    _initFfi();
  }

  late final _FindWindowWDart _findWindow;
  late final _GetForegroundWindowDart _getForegroundWindow;
  late final _GetActiveWindowDart _getActiveWindow;
  late final _ClientToScreenDart _clientToScreen;
  late final _GetWindowLongPtrWDart _getWindowLongPtr;
  late final _SetWindowLongPtrWDart _setWindowLongPtr;
  late final _SetWindowPosDart _setWindowPos;
  late final _PostMessageWDart _postMessage;

  int _scrcpyHwnd = 0;
  int _parentHwnd = 0;
  int _originalStyle = 0;
  bool _docked = false;

  void _initFfi() {
    final user32 = DynamicLibrary.open('user32.dll');

    _findWindow = user32.lookupFunction<_FindWindowWC, _FindWindowWDart>(
      'FindWindowW',
    );
    _getForegroundWindow = user32
        .lookupFunction<_GetForegroundWindowC, _GetForegroundWindowDart>(
          'GetForegroundWindow',
        );
    _getActiveWindow = user32
        .lookupFunction<_GetActiveWindowC, _GetActiveWindowDart>(
          'GetActiveWindow',
        );
    _clientToScreen = user32
        .lookupFunction<_ClientToScreenC, _ClientToScreenDart>('ClientToScreen');
    _getWindowLongPtr = user32.lookupFunction<
      _GetWindowLongPtrWC,
      _GetWindowLongPtrWDart
    >('GetWindowLongPtrW');
    _setWindowLongPtr = user32.lookupFunction<
      _SetWindowLongPtrWC,
      _SetWindowLongPtrWDart
    >('SetWindowLongPtrW');
    _setWindowPos = user32.lookupFunction<_SetWindowPosC, _SetWindowPosDart>(
      'SetWindowPos',
    );
    _postMessage = user32.lookupFunction<_PostMessageWC, _PostMessageWDart>(
      'PostMessageW',
    );
  }

  @override
  bool get isSupported => Platform.isWindows;

  int _findFlutterHwnd() {
    if (!Platform.isWindows) return 0;

    int hwnd = _getForegroundWindow();
    if (hwnd != 0) return hwnd;

    hwnd = _getActiveWindow();
    if (hwnd != 0) return hwnd;

    final classPtr = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    hwnd = _findWindow(classPtr, nullptr);
    calloc.free(classPtr);
    if (hwnd != 0) return hwnd;

    final titlePtr = 'wcat'.toNativeUtf16();
    hwnd = _findWindow(nullptr, titlePtr);
    calloc.free(titlePtr);

    return hwnd;
  }

  bool _isClosed = false;

  Future<int?> _findScrcpyHwnd(
    String title, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final titlePtr = title.toNativeUtf16();
    final stopwatch = Stopwatch()..start();
    try {
      while (stopwatch.elapsed < timeout && !_isClosed) {
        final hwnd = _findWindow(nullptr, titlePtr);
        if (hwnd != 0) return hwnd;
        await Future.delayed(const Duration(milliseconds: 80));
      }
    } finally {
      calloc.free(titlePtr);
    }
    return null;
  }

  @override
  Future<bool> dock({
    required String windowTitle,
    required Rect bounds,
    required double devicePixelRatio,
  }) async {
    if (!isSupported) return false;

    final scrcpy = await _findScrcpyHwnd(windowTitle);
    if (scrcpy == null || scrcpy == 0) return false;

    _scrcpyHwnd = scrcpy;
    _docked = true;

    final flutterHwnd = _findFlutterHwnd();
    if (flutterHwnd != 0) {
      _parentHwnd = flutterHwnd;
      // Set Flutter window as owner so scrcpy window stays above Flutter and minimizes with Flutter
      _setWindowLongPtr(_scrcpyHwnd, _gwlpHwndParent, _parentHwnd);
    }

    _originalStyle = _getWindowLongPtr(_scrcpyHwnd, _gwlStyle);

    // Keep top-level WS_POPUP style to allow Direct3D11 flip-model presentation
    int borderlessStyle = _originalStyle;
    borderlessStyle &= ~(
      _wsCaption |
      _wsThickFrame |
      _wsMinimizeBox |
      _wsMaximizeBox |
      _wsSysMenu
    );
    borderlessStyle |= (_wsPopup | _wsVisible);
    _setWindowLongPtr(_scrcpyHwnd, _gwlStyle, borderlessStyle);

    updateBounds(bounds: bounds, devicePixelRatio: devicePixelRatio);
    return true;
  }

  @override
  void updateBounds({
    required Rect bounds,
    required double devicePixelRatio,
  }) {
    if (_scrcpyHwnd == 0 || !_docked) return;

    int screenX = (bounds.left * devicePixelRatio).round();
    int screenY = (bounds.top * devicePixelRatio).round();
    final screenW = (bounds.width * devicePixelRatio).round();
    final screenH = (bounds.height * devicePixelRatio).round();

    if (_parentHwnd != 0) {
      final pt = calloc<_POINT>();
      pt.ref.x = screenX;
      pt.ref.y = screenY;
      final ok = _clientToScreen(_parentHwnd, pt);
      if (ok != 0) {
        screenX = pt.ref.x;
        screenY = pt.ref.y;
      }
      calloc.free(pt);
    }

    _setWindowPos(
      _scrcpyHwnd,
      _hwndTop,
      screenX,
      screenY,
      screenW,
      screenH,
      _swpNoActivate | _swpFrameChanged | _swpShowWindow,
    );
  }

  @override
  void undock() {
    if (_scrcpyHwnd == 0) return;
    _docked = false;

    // Remove owner window
    _setWindowLongPtr(_scrcpyHwnd, _gwlpHwndParent, 0);

    // Reposition as independent floating desktop window
    _setWindowPos(
      _scrcpyHwnd,
      _hwndTop,
      120,
      120,
      420,
      850,
      _swpFrameChanged | _swpShowWindow,
    );
  }

  @override
  void close() {
    _isClosed = true;
    if (_scrcpyHwnd != 0) {
      _postMessage(_scrcpyHwnd, _wmClose, 0, 0);
      _scrcpyHwnd = 0;
      _docked = false;
    }
  }
}
