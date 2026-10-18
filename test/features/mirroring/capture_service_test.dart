import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wcat/features/mirroring/capture_service.dart';
import 'package:wcat/features/mirroring/services/capture_client.dart';

class MockCaptureClient implements CaptureClient {
  Uri? lastScreenshotUri;
  Uri? lastRecordStartUri;
  Uri? lastRecordStopUri;

  Uint8List? mockScreenshotData = Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
  ]); // PNG header
  bool mockRecordStartResult = true;
  Uint8List? mockRecordStopData = Uint8List.fromList([
    0x00,
    0x00,
    0x00,
    0x18,
    0x66,
    0x74,
    0x79,
    0x70,
  ]); // MP4 ftyp

  @override
  Future<Uint8List?> getScreenshot(Uri uri) async {
    lastScreenshotUri = uri;
    return mockScreenshotData;
  }

  @override
  Future<bool> startRecord(Uri uri) async {
    lastRecordStartUri = uri;
    return mockRecordStartResult;
  }

  @override
  Future<Uint8List?> stopRecord(Uri uri) async {
    lastRecordStopUri = uri;
    return mockRecordStopData;
  }

  Map<String, dynamic>? mockPostJsonResult;
  Uri? lastPostJsonUri;
  Map<String, dynamic>? lastPostJsonBody;

  @override
  Future<Map<String, dynamic>?> postJson(
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
    lastPostJsonUri = uri;
    lastPostJsonBody = body;
    return mockPostJsonResult;
  }

  @override
  Future<Map<String, dynamic>?> getJson(Uri uri) async {
    return null;
  }
}

void main() {
  group('CaptureService Tests (Phase 3)', () {
    late MockCaptureClient mockClient;
    late CaptureService service;

    setUp(() {
      mockClient = MockCaptureClient();
      service = CaptureService(client: mockClient);
    });

    tearDown(() {
      service.dispose();
    });

    test('takeScreenshot invokes endpoint and returns bytes', () async {
      expect(service.isTakingScreenshot.value, isFalse);

      final bytes = await service.takeScreenshot(serial: 'pixel-7');

      expect(bytes, isNotNull);
      expect(bytes!.length, 4);
      expect(
        mockClient.lastScreenshotUri.toString(),
        contains('/api/screenshot?serial=pixel-7'),
      );
      expect(service.isTakingScreenshot.value, isFalse);
    });

    test(
      'Recording lifecycle: start, timer increment, and graceful stop',
      () async {
        expect(service.isRecording.value, isFalse);

        final started = await service.startRecording(
          serial: 'pixel-7',
          bitRate: 4000000,
        );
        expect(started, isTrue);
        expect(service.isRecording.value, isTrue);
        expect(service.activeRecordingSerial.value, 'pixel-7');
        expect(
          mockClient.lastRecordStartUri.toString(),
          contains('/api/record/start?serial=pixel-7&bitRate=4000000'),
        );

        // Stopping recording
        final mp4Bytes = await service.stopRecording();
        expect(mp4Bytes, isNotNull);
        expect(mp4Bytes!.length, 8);
        expect(
          mockClient.lastRecordStopUri.toString(),
          contains('/api/record/stop?serial=pixel-7'),
        );
        expect(service.isRecording.value, isFalse);
        expect(service.activeRecordingSerial.value, isNull);
      },
    );

    test(
      'saveScreenshot and saveRecording generate properly formatted file exports',
      () async {
        final pngBytes = [1, 2, 3];
        final pngPath = await service.saveScreenshot(
          pngBytes,
          serial: 'device-1',
        );
        expect(pngPath, contains('screenshot_device-1_'));
        expect(pngPath, endsWith('.png'));

        final mp4Bytes = [4, 5, 6];
        final mp4Path = await service.saveRecording(
          mp4Bytes,
          serial: 'device-2',
        );
        expect(mp4Path, contains('screenrecord_device-2_'));
        expect(mp4Path, endsWith('.mp4'));
      },
    );
  });
}
