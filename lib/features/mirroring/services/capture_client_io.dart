import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class CaptureClient {
  final HttpClient _client = HttpClient();

  /// Fetches screenshot PNG bytes from the bridge.
  /// Returns null and rethrows the error message if the bridge returns an error status.
  Future<Uint8List?> getScreenshot(Uri uri) async {
    final req = await _client.getUrl(uri);
    final res = await req.close();
    if (res.statusCode == HttpStatus.ok) {
      final builder = BytesBuilder();
      await for (final chunk in res) {
        builder.add(chunk);
      }
      return builder.toBytes();
    }
    // Surface the error body so the caller can show it to the user
    final errBody = await utf8.decoder.bind(res).join();
    throw HttpException(
      'Screenshot failed (HTTP ${res.statusCode}): $errBody',
      uri: uri,
    );
  }

  /// Starts a screen recording session on the bridge.
  /// Returns true on success; throws on network or HTTP error.
  Future<bool> startRecord(Uri uri) async {
    final req = await _client.postUrl(uri);
    final res = await req.close();
    if (res.statusCode == HttpStatus.ok) return true;
    final errBody = await utf8.decoder.bind(res).join();
    throw HttpException(
      'Start recording failed (HTTP ${res.statusCode}): $errBody',
      uri: uri,
    );
  }

  /// Stops recording and streams back the MP4 bytes.
  /// Returns null if the bridge returned no content; throws on error.
  Future<Uint8List?> stopRecord(Uri uri) async {
    final req = await _client.postUrl(uri);
    final res = await req.close();
    if (res.statusCode == HttpStatus.ok) {
      final builder = BytesBuilder();
      await for (final chunk in res) {
        builder.add(chunk);
      }
      final bytes = builder.toBytes();
      return bytes.isNotEmpty ? bytes : null;
    }
    final errBody = await utf8.decoder.bind(res).join();
    throw HttpException(
      'Stop recording failed (HTTP ${res.statusCode}): $errBody',
      uri: uri,
    );
  }

  Future<Map<String, dynamic>?> getJson(Uri uri) async {
    try {
      final req = await _client.getUrl(uri);
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      if (text.isNotEmpty) {
        return jsonDecode(text) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> postJson(
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
    try {
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      if (body != null) {
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      if (text.isNotEmpty) {
        return jsonDecode(text) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }
}
