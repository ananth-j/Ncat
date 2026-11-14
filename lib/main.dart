import 'package:flutter/material.dart';

import 'app.dart';

// Re-export core types and primary components for backward compatibility and test convenience
export 'app.dart';
export 'core/constants.dart';
export 'features/devices/models/device_info.dart';
export 'features/logcat/models/log_entry.dart';
export 'features/logcat/pages/logcat_page.dart';
export 'src/column_config.dart';
export 'src/palette.dart';

/// Clean application entrypoint initializing bindings and bootstrapping the app.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LogcatApp());
}
