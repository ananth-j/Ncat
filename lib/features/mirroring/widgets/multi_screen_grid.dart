import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../src/palette.dart';
import '../../devices/models/device_info.dart';
import '../capture_service.dart';
import '../mirror_controller.dart';
import 'scrcpy_install_dialog.dart';

/// Responsive multi-device matrix grid (Phase 5).
class MultiScreenGrid extends StatefulWidget {
  const MultiScreenGrid({
    super.key,
    required this.devices,
    required this.captureService,
    required this.onSelectDevice,
    this.activeSerial,
    this.onCloseGrid,
  });

  final List<DeviceInfo> devices;
  final CaptureService captureService;
  final ValueChanged<String> onSelectDevice;
  final String? activeSerial;
  final VoidCallback? onCloseGrid;

  @override
  State<MultiScreenGrid> createState() => _MultiScreenGridState();
}

class _MultiScreenGridState extends State<MultiScreenGrid> {
  final Map<String, MirrorController> _controllers = {};
  final Map<String, Uint8List?> _snapshots = {};
  bool _isBulkActionInProgress = false;

  @override
  void initState() {
    super.initState();
    _initDeviceControllers();
  }

  @override
  void didUpdateWidget(covariant MultiScreenGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _initDeviceControllers();
  }

  void _initDeviceControllers() {
    for (final dev in widget.devices) {
      if (!_controllers.containsKey(dev.serial)) {
        _controllers[dev.serial] = MirrorController();
      }
    }
  }

  Future<void> _refreshSnapshot(String serial) async {
    final bytes = await widget.captureService.takeScreenshot(serial: serial);
    if (mounted && bytes != null) {
      setState(() {
        _snapshots[serial] = bytes;
      });
    }
  }

  Future<void> _screenshotAll() async {
    if (_isBulkActionInProgress) return;
    setState(() => _isBulkActionInProgress = true);

    int count = 0;
    try {
      final futures = widget.devices.map((d) async {
        final bytes = await widget.captureService.takeScreenshot(
          serial: d.serial,
        );
        if (bytes != null) {
          await widget.captureService.saveScreenshot(bytes, serial: d.serial);
          count++;
        }
      });
      await Future.wait(futures);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Bulk action: Captured and saved screenshots for $count devices',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isBulkActionInProgress = false);
    }
  }

  void _mirrorAll() {
    for (final dev in widget.devices) {
      final ctrl = _controllers[dev.serial];
      ctrl?.launchScrcpy(serial: dev.serial);
    }
  }

  @override
  void dispose() {
    for (final ctrl in _controllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      color: palette.bg,
      child: Column(
        children: [
          _buildToolbar(palette),
          Expanded(child: _buildGrid(palette)),
        ],
      ),
    );
  }

  Widget _buildToolbar(AppPalette palette) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Icon(Icons.grid_view_rounded, size: 16, color: palette.accent),
            const SizedBox(width: 8),
            Text(
              'Multi-Device Matrix (${widget.devices.length} Devices)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: palette.text,
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: palette.accentBg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: palette.accent),
              ),
              child: Text(
                'scrcpy 60 FPS',
                style: TextStyle(
                  fontSize: 10,
                  color: palette.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 16),

            // Bulk action: Screenshot All (Phase 5.3)
            OutlinedButton.icon(
              icon: const Icon(Icons.camera_alt_outlined, size: 14),
              label: const Text(
                'Screenshot All',
                style: TextStyle(fontSize: 11),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                side: BorderSide(color: palette.border),
                foregroundColor: palette.text,
              ),
              onPressed: _isBulkActionInProgress ? null : _screenshotAll,
            ),
            const SizedBox(width: 8),

            // Bulk action: Mirror All (Phase 5.3)
            OutlinedButton.icon(
              icon: const Icon(Icons.screen_share_outlined, size: 14),
              label: const Text(
                'Mirror All (scrcpy)',
                style: TextStyle(fontSize: 11),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                side: BorderSide(color: palette.border),
                foregroundColor: palette.text,
              ),
              onPressed: _mirrorAll,
            ),
            const SizedBox(width: 8),

            if (widget.onCloseGrid != null)
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Exit Matrix View',
                color: palette.dim,
                onPressed: widget.onCloseGrid,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(AppPalette palette) {
    if (widget.devices.isEmpty) {
      return Center(
        child: Text(
          'No connected Android devices detected',
          style: TextStyle(color: palette.dim),
        ),
      );
    }

    final crossAxisCount =
        widget.devices.length <= 2 ? widget.devices.length : 2;

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount.clamp(1, 4),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.85,
      ),
      itemCount: widget.devices.length,
      itemBuilder: (context, i) {
        final dev = widget.devices[i];
        final ctrl = _controllers[dev.serial];

        return _buildDeviceTile(dev, ctrl, palette);
      },
    );
  }

  Widget _buildDeviceTile(
    DeviceInfo dev,
    MirrorController? ctrl,
    AppPalette palette,
  ) {
    final isSelected = dev.serial == widget.activeSerial;

    return Container(
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected ? palette.accent : palette.border,
          width: isSelected ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          // Tile header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: palette.bg,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(7),
              ),
              border: Border(bottom: BorderSide(color: palette.border)),
            ),
            child: Row(
              children: [
                Icon(
                  dev.authorized
                      ? Icons.check_circle
                      : Icons.warning_amber_rounded,
                  size: 14,
                  color:
                      dev.authorized
                          ? const Color(0xFF43A047)
                          : const Color(0xFFE53935),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        (dev.model != null && dev.model!.isNotEmpty)
                            ? dev.model!
                            : dev.serial,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: palette.text,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        dev.serial,
                        style: TextStyle(fontSize: 9, color: palette.dim),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),

                // scrcpy standalone mirror launch
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 12),
                  label: const Text('Mirror', style: TextStyle(fontSize: 10)),
                  onPressed: () async {
                    final ctrl = _controllers[dev.serial];
                    if (ctrl == null) return;
                    final status = await ctrl.launchScrcpyWithStatus(
                      serial: dev.serial,
                    );
                    if (!mounted) return;
                    if (status == 'not_installed') {
                      await ScrcpyInstallDialog.show(
                        context: context,
                        controller: ctrl,
                        serial: dev.serial,
                      );
                    }
                  },
                ),

                IconButton(
                  icon: const Icon(Icons.list_alt, size: 14),
                  tooltip: 'View logs in main console',
                  color: palette.dim,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  onPressed: () => widget.onSelectDevice(dev.serial),
                ),
              ],
            ),
          ),

          // Screen preview
          Expanded(child: _buildStaticSnapshotTile(dev.serial, palette)),
        ],
      ),
    );
  }

  Widget _buildStaticSnapshotTile(String serial, AppPalette palette) {
    final snapshotBytes = _snapshots[serial];

    if (snapshotBytes != null) {
      return Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.all(6.0),
            child: Image.memory(snapshotBytes, fit: BoxFit.contain),
          ),
          Positioned(
            bottom: 8,
            right: 8,
            child: FloatingActionButton.small(
              heroTag: 'refresh_$serial',
              backgroundColor: palette.panel,
              child: Icon(Icons.refresh, size: 16, color: palette.text),
              onPressed: () => _refreshSnapshot(serial),
            ),
          ),
        ],
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.phone_android,
            size: 36,
            color: palette.dim.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.camera_alt_outlined, size: 12),
            label: const Text(
              'Capture Snapshot',
              style: TextStyle(fontSize: 10),
            ),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
            ),
            onPressed: () => _refreshSnapshot(serial),
          ),
        ],
      ),
    );
  }
}
