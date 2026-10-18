import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class CaptureClient {
  final HttpClient _client = HttpClient();

  Future<Uint8List?> getScreenshot(Uri uri) async {
    try {
      final req = await _client.getUrl(uri);
      final res = await req.close();
      if (res.statusCode == HttpStatus.ok) {
        final builder = BytesBuilder();
        await for (final chunk in res) {
          builder.add(chunk);
        }
        return builder.toBytes();
      }
    } catch (_) {}
    return null;
  }

  Future<bool> startRecord(Uri uri) async {
    try {
      final req = await _client.postUrl(uri);
      final res = await req.close();
      return res.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> stopRecord(Uri uri) async {
    try {
      final req = await _client.postUrl(uri);
      final res = await req.close();
      if (res.statusCode == HttpStatus.ok) {
        final builder = BytesBuilder();
        await for (final chunk in res) {
          builder.add(chunk);
        }
        return builder.toBytes();
      }
    } catch (_) {}
    return null;
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
