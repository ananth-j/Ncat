import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Triggers a browser download of [content] as [filename].
Future<String> exportLog(String content, String filename) async {
  final blob = web.Blob(
    [utf8.encode(content).toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor =
      web.HTMLAnchorElement()
        ..href = url
        ..download = filename;
  anchor.click();
  web.URL.revokeObjectURL(url);
  return 'downloaded as $filename';
}

/// Triggers a browser download of binary [bytes] as [filename].
Future<String> exportBinary(List<int> bytes, String filename) async {
  final uint8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final blob = web.Blob(
    [uint8.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor =
      web.HTMLAnchorElement()
        ..href = url
        ..download = filename;
  anchor.click();
  web.URL.revokeObjectURL(url);
  return 'downloaded as $filename';
}
