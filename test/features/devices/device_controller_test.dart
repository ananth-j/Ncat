import 'package:flutter_test/flutter_test.dart';
import 'package:thruwire/features/devices/device_controller.dart';
import 'package:thruwire/features/devices/models/device_info.dart';

void main() {
  group('DeviceController Unit Tests', () {
    late DeviceController controller;

    setUp(() {
      controller = DeviceController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('initializes with default values', () {
      expect(controller.devices, isEmpty);
      expect(controller.activeDevice, isNull);
      expect(controller.pickedDevice, isNull);
      expect(controller.viewMode, DeviceViewMode.singleOrTabs);
      expect(controller.tabStates, isEmpty);
    });

    test('updateDevices populates devices and automatically selects first device', () {
      const dev1 = DeviceInfo(serial: 'dev-1', model: 'Pixel 8');
      const dev2 = DeviceInfo(serial: 'dev-2', model: 'Galaxy S24');

      controller.updateDevices([dev1, dev2]);

      expect(controller.devices.length, 2);
      expect(controller.activeDevice, 'dev-1');
      expect(controller.pickedDevice, 'dev-1');
    });

    test('updateDevices cleans up stale tab states when device disconnects', () {
      const dev1 = DeviceInfo(serial: 'dev-1');
      const dev2 = DeviceInfo(serial: 'dev-2');

      controller.updateDevices([dev1, dev2]);
      controller.getOrCreateTab('dev-1');
      controller.getOrCreateTab('dev-2');
      expect(controller.tabStates.length, 2);

      // dev-2 is disconnected
      controller.updateDevices([dev1]);
      expect(controller.tabStates.containsKey('dev-2'), isFalse);
      expect(controller.tabStates.containsKey('dev-1'), isTrue);
    });

    test('toggleViewMode toggles between singleOrTabs and grid', () {
      expect(controller.viewMode, DeviceViewMode.singleOrTabs);

      controller.toggleViewMode();
      expect(controller.viewMode, DeviceViewMode.grid);

      controller.toggleViewMode();
      expect(controller.viewMode, DeviceViewMode.singleOrTabs);
    });

    test('setActiveDevice updates active and picked device and notifies listeners', () {
      var notified = false;
      controller.addListener(() => notified = true);

      controller.setActiveDevice('test-serial');
      expect(controller.activeDevice, 'test-serial');
      expect(controller.pickedDevice, 'test-serial');
      expect(notified, isTrue);
    });

    test('applyDevice updates selection', () {
      controller.applyDevice('dev-99');
      expect(controller.activeDevice, 'dev-99');
      expect(controller.pickedDevice, 'dev-99');
    });
  });
}
