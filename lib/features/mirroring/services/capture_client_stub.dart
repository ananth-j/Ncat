import 'dart:typed_data';

abstract class CaptureClient {
  factory CaptureClient() =>
      throw UnsupportedError('Cannot create CaptureClient');
  Future<Uint8List?> getScreenshot(Uri uri);
  Future<bool> startRecord(Uri uri);
  Future<Uint8List?> stopRecord(Uri uri);
  Future<Map<String, dynamic>?> postJson(Uri uri, [Map<String, dynamic>? body]);
}
