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

// Win32 Constants
const int _gwlStyle = -16;
const int _wsPopup = 0x80000000;
const int _wsCaption = 0x00C00000;
const int _wsThickFrame = 0x00040000;
const int _wsMinimizeBox = 0x00020000;
const int _wsMaximizeBox = 0x00010000;
const int _wsSysMenu = 0x00080000;
const int _wsChild = 0x40000000;
const int _wsVisible = 0x10000000;
const int _wsClipSiblings = 0x04000000;

const int _hwndTop = 0;
const int _swpNoActivate = 0x0010;
const int _swpFrameChanged = 0x0020;
const int _swpShowWindow = 0x0040;

const int _wmClose = 0x0010;

// Win32 FFI Signatures
typedef _GetCurrentProcessIdC = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();

typedef _EnumWindowsProc = Int32 Function(IntPtr hwnd, IntPtr lParam);
typedef _EnumWindowsC = Int32 Function(
  Pointer<NativeFunction<_EnumWindowsProc>> lpEnumFunc,
  IntPtr lParam,
);
typedef _EnumWindowsDart = int Function(
  Pointer<NativeFunction<_EnumWindowsProc>> lpEnumFunc,
  int lParam,
);

typedef _GetWindowThreadProcessIdC = Uint32 Function(
  IntPtr hwnd,
  Pointer<Uint32> lpdwProcessId,
);
typedef _GetWindowThreadProcessIdDart = int Function(
  int hwnd,
  Pointer<Uint32> lpdwProcessId,
);

typedef _FindWindowWC = IntPtr Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);
typedef _FindWindowWDart = int Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);

typedef _FindWindowExWC = IntPtr Function(
  IntPtr hWndParent,
  IntPtr hWndChildAfter,
  Pointer<Utf16> lpszClass,
  Pointer<Utf16> lpszWindow,
);
typedef _FindWindowExWDart = int Function(
  int hWndParent,
  int hWndChildAfter,
  Pointer<Utf16> lpszClass,
  Pointer<Utf16> lpszWindow,
);

typedef _SetParentC = IntPtr Function(IntPtr hWndChild, IntPtr hWndNewParent);
typedef _SetParentDart = int Function(int hWndChild, int hWndNewParent);

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

typedef _IsWindowVisibleC = Int32 Function(IntPtr hWnd);
typedef _IsWindowVisibleDart = int Function(int hWnd);

/// Windows native implementation of window reparenting and docking via Win32 user32/kernel32.
class ScrcpyDockWin32 implements ScrcpyDockService {
  ScrcpyDockWin32() {
    _initFfi();
  }

  late final _GetCurrentProcessIdDart _getCurrentProcessId;
  late final _EnumWindowsDart _enumWindows;
  late final _GetWindowThreadProcessIdDart _getWindowThreadProcessId;
  late final _FindWindowWDart _findWindow;
  late final _FindWindowExWDart _findWindowEx;
  late final _SetParentDart _setParent;
  late final _GetWindowLongPtrWDart _getWindowLongPtr;
  late final _SetWindowLongPtrWDart _setWindowLongPtr;
  late final _SetWindowPosDart _setWindowPos;
  late final _PostMessageWDart _postMessage;
  late final _IsWindowVisibleDart _isWindowVisible;

  int _scrcpyHwnd = 0;
  int _parentHwnd = 0;
  int _originalStyle = 0;
  bool _docked = false;

  void _initFfi() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final user32 = DynamicLibrary.open('user32.dll');

    _getCurrentProcessId = kernel32
        .lookupFunction<_GetCurrentProcessIdC, _GetCurrentProcessIdDart>(
          'GetCurrentProcessId',
        );

    _enumWindows = user32.lookupFunction<_EnumWindowsC, _EnumWindowsDart>(
      'EnumWindows',
    );
    _getWindowThreadProcessId = user32.lookupFunction<
      _GetWindowThreadProcessIdC,
      _GetWindowThreadProcessIdDart
    >('GetWindowThreadProcessId');
    _findWindow = user32.lookupFunction<_FindWindowWC, _FindWindowWDart>(
      'FindWindowW',
    );
    _findWindowEx = user32.lookupFunction<_FindWindowExWC, _FindWindowExWDart>(
      'FindWindowExW',
    );
    _setParent = user32.lookupFunction<_SetParentC, _SetParentDart>('SetParent');
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
    _isWindowVisible = user32
        .lookupFunction<_IsWindowVisibleC, _IsWindowVisibleDart>(
          'IsWindowVisible',
        );
  }

  @override
  bool get isSupported => Platform.isWindows;

  int? _findFlutterHwnd() {
    if (!Platform.isWindows) return null;
    final currentPid = _getCurrentProcessId();
    int rootHwnd = 0;

    final callback = NativeCallable<_EnumWindowsProc>.isolateLocal((
      int hwnd,
      int lParam,
    ) {
      final pidPtr = calloc<Uint32>();
      _getWindowThreadProcessId(hwnd, pidPtr);
      final pid = pidPtr.value;
      calloc.free(pidPtr);

      if (pid == currentPid && _isWindowVisible(hwnd) != 0) {
        rootHwnd = hwnd;
        return 0; // stop enumeration
      }
      return 1; // continue
    }, exceptionalReturn: 0);

    _enumWindows(callback.nativeFunction, 0);
    callback.close();

    if (rootHwnd == 0) return null;

    final viewClassPtr = 'FLUTTERVIEW'.toNativeUtf16();
    final viewHwnd = _findWindowEx(rootHwnd, 0, viewClassPtr, nullptr);
    calloc.free(viewClassPtr);

    return viewHwnd != 0 ? viewHwnd : rootHwnd;
  }

  Future<int?> _findScrcpyHwnd(
    String title, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final titlePtr = title.toNativeUtf16();
    final stopwatch = Stopwatch()..start();
    try {
      while (stopwatch.elapsed < timeout) {
        final hwnd = _findWindow(nullptr, titlePtr);
        if (hwnd != 0) return hwnd;
        await Future.delayed(const Duration(milliseconds: 60));
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

    final parent = _findFlutterHwnd();
    if (parent == null || parent == 0) return false;
    _parentHwnd = parent;

    final scrcpy = await _findScrcpyHwnd(windowTitle);
    if (scrcpy == null || scrcpy == 0) return false;

    _scrcpyHwnd = scrcpy;
    _docked = true;

    _originalStyle = _getWindowLongPtr(_scrcpyHwnd, _gwlStyle);

    int newStyle = _originalStyle;
    newStyle &= ~(
      _wsPopup |
      _wsCaption |
      _wsThickFrame |
      _wsMinimizeBox |
      _wsMaximizeBox |
      _wsSysMenu
    );
    newStyle |= (_wsChild | _wsVisible | _wsClipSiblings);
    _setWindowLongPtr(_scrcpyHwnd, _gwlStyle, newStyle);

    _setParent(_scrcpyHwnd, _parentHwnd);

    updateBounds(bounds: bounds, devicePixelRatio: devicePixelRatio);
    return true;
  }

  @override
  void updateBounds({
    required Rect bounds,
    required double devicePixelRatio,
  }) {
    if (_scrcpyHwnd == 0 || !_docked) return;

    final x = (bounds.left * devicePixelRatio).round();
    final y = (bounds.top * devicePixelRatio).round();
    final w = (bounds.width * devicePixelRatio).round();
    final h = (bounds.height * devicePixelRatio).round();

    _setWindowPos(
      _scrcpyHwnd,
      _hwndTop,
      x,
      y,
      w,
      h,
      _swpNoActivate | _swpFrameChanged | _swpShowWindow,
    );
  }

  @override
  void undock() {
    if (_scrcpyHwnd == 0 || !_docked) return;
    _docked = false;

    _setParent(_scrcpyHwnd, 0); // 0 = Desktop root

    int restoredStyle =
        _originalStyle != 0
            ? _originalStyle
            : (
              _wsPopup |
              _wsVisible |
              _wsCaption |
              _wsThickFrame |
              _wsSysMenu
            );
    restoredStyle &= ~_wsChild;
    restoredStyle |= (
      _wsPopup |
      _wsVisible |
      _wsCaption |
      _wsThickFrame |
      _wsSysMenu
    );
    _setWindowLongPtr(_scrcpyHwnd, _gwlStyle, restoredStyle);

    _setWindowPos(
      _scrcpyHwnd,
      _hwndTop,
      120,
      120,
      400,
      800,
      _swpFrameChanged | _swpShowWindow,
    );
  }

  @override
  void close() {
    if (_scrcpyHwnd != 0) {
      _postMessage(_scrcpyHwnd, _wmClose, 0, 0);
      _scrcpyHwnd = 0;
      _docked = false;
    }
  }
}
