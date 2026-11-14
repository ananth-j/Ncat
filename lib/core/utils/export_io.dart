import 'dart:io';

/// Writes [content] to the platform Downloads folder and returns the path
/// written to, falling back to the home directory if Downloads doesn't exist.
Future<String> exportLog(String content, String filename) async {
  final file = File('${_downloadsDir()}${Platform.pathSeparator}$filename');
  await file.writeAsString(content);
  return file.path;
}

/// Writes binary [bytes] to the platform Downloads folder and returns the path.
Future<String> exportBinary(List<int> bytes, String filename) async {
  final file = File('${_downloadsDir()}${Platform.pathSeparator}$filename');
  await file.writeAsBytes(bytes);
  return file.path;
}

String _downloadsDir() {
  final home =
      Platform.isWindows
          ? (Platform.environment['USERPROFILE'] ?? '.')
          : (Platform.environment['HOME'] ?? '.');
  final downloads = '$home${Platform.pathSeparator}Downloads';
  return Directory(downloads).existsSync() ? downloads : home;
}
