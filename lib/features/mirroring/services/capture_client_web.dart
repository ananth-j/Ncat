import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class CaptureClient {
  Future<Uint8List?> getScreenshot(Uri uri) async {
    try {
      final res = await web.window.fetch(uri.toString().toJS).toDart;
      if (res.status == 200) {
        final buffer = await res.arrayBuffer().toDart;
        return buffer.toDart.asUint8List();
      }
    } catch (_) {}
    return null;
  }

  Future<bool> startRecord(Uri uri) async {
    try {
      final init = web.RequestInit(method: 'POST');
      final res = await web.window.fetch(uri.toString().toJS, init).toDart;
      return res.status == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> stopRecord(Uri uri) async {
    try {
      final init = web.RequestInit(method: 'POST');
      final res = await web.window.fetch(uri.toString().toJS, init).toDart;
      if (res.status == 200) {
        final buffer = await res.arrayBuffer().toDart;
        return buffer.toDart.asUint8List();
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> getJson(Uri uri) async {
    try {
      final res = await web.window.fetch(uri.toString().toJS).toDart;
      final text = (await res.text().toDart).toDart;
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
      final headers = web.Headers();
      headers.append('Content-Type', 'application/json');
      final init = web.RequestInit(
        method: 'POST',
        headers: headers,
        body: body != null ? jsonEncode(body).toJS : null,
      );
      final res = await web.window.fetch(uri.toString().toJS, init).toDart;
      final text = (await res.text().toDart).toDart;
      if (text.isNotEmpty) {
        return jsonDecode(text) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }
}
