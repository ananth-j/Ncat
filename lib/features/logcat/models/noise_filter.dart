import 'log_entry.dart';

/// Display mode for Android system noise suppression.
enum NoiseFilterMode {
  /// Suppresses high-frequency Android OS and hardware daemon noise (Wi-Fi,
  /// Bluetooth, SurfaceFlinger, audio polling, etc.).
  /// Real application logs and all Warning/Error/Fatal lines are preserved.
  reduce,

  /// Displays all logs as emitted by logcat without noise suppression.
  showAll,

  /// Displays only the logs classified as noise (useful for diagnosing system services).
  onlyNoise,
}

/// Helper that identifies repetitive Android OS background chatter and hardware daemons.
class NoiseFilter {
  /// Normalized lowercase set of Android OS daemon and framework tags that frequently
  /// spam logcat without providing user-app debugging value.
  static final Set<String> _knownNoiseTagsLower = {
    // Throttling / Logcat internals
    'chatty',

    // Graphics, Surface compositor, HWUI
    'surfaceflinger',
    'hwcomposer',
    'gralloc',
    'renderengine',
    'bufferqueue',
    'bufferqueueproducer',
    'bufferqueueconsumer',
    'layer',
    'colorspace',
    'glconsumer',
    'viewrootimpl',

    // Audio / Media daemons
    'audioflinger',
    'audiopolicymanager',
    'audiopolicyservice',
    'audiotrack',
    'audiosystem',
    'audiorecord',
    'soundpool',
    'mediacodec',

    // Wi-Fi, Ethernet & Network stack
    'wifiservice',
    'wifihal',
    'wpa_supplicant',
    'wificonnectivitymanager',
    'wifinetworkagent',
    'wifistatemachine',
    'networkmonitor',
    'netd',
    'connectivityservice',
    'dhcpclient',
    'ipclient',
    'networkmanagement',
    'ethernettracker',
    'tethering',
    'dnsresponder',

    // Bluetooth stack
    'bt_stack',
    'btgatt',
    'bluetoothadapter',
    'bt_btif',
    'bt_bta',
    'bt_osi',
    'bluetoothheadset',
    'bluetoothdevice',
    'bt_core',

    // Power, Battery & Thermal management
    'batterystatsservice',
    'batteryservice',
    'powermanagerservice',
    'powerhal',
    'thermalengine',
    'lights',
    'healthservice',

    // Location / GNSS / GPS
    'gnsshal',
    'gpslocationprovider',
    'locationmanagerservice',
    'locsvc_api_v02',
    'fusedlocationprovider',
    'gnsslocationprovider',

    // Telephony / RIL
    'rilj',
    'rilc',
    'telecom',
    'telephonyregistry',
    'phoneinterfacemanager',
    'telephonyprovider',
    'carrierservices',

    // Input / Hardware events
    'inputreader',
    'inputdispatcher',
    'pointercontroller',

    // Alarms / Periodic schedulers / Broadcast queues
    'alarmmanager',
    'jobscheduler',
    'broadcastqueue',
    'alarmmanagerservice',
    'periodictask',

    // Google Mobile Services (GMS) background telemetry & sync
    'gcoreflp',
    'gmsnetworklocationprovider',
    'nearbydiscovery',
    'clearcutmetricclient',
    'phenotype',
    'contextmanager',
    'chimera',
    'googleplayservices',
    'compatibilitychangereporter',
    'auditlog',

    // Sensor polling
    'sensorservice',
    'sensormanager',
    'sensors',

    // Choreographer routine frame skips
    'choreographer',
  };

  /// Common prefixes indicating hardware or OS subsystems.
  static final List<String> _noisePrefixes = [
    'wifi',
    'audio',
    'bt_',
    'surfaceflinger',
    'gnss',
    'hwcomposer',
  ];

  /// Evaluates whether a given [LogEntry] constitutes system background noise.
  ///
  /// CRITICAL RULES:
  /// 1. Severity 'W' (Warning), 'E' (Error), 'F' / 'S' (Fatal / Assert) are **never** noise.
  ///    Crashes, runtime exceptions, and warnings must always remain visible.
  /// 2. If [appPid] or [packageFilter] is specified and matches the entry, it is **never** noise.
  static bool isNoise(
    LogEntry entry, {
    int? appPid,
    String? packageFilter,
  }) {
    // 1. Warnings, errors, and fatal crashes are NEVER suppressed as noise.
    if (entry.rank >= 3) return false;

    // 2. Entries belonging to the explicitly targeted app or PID are never noise.
    if (appPid != null && entry.pid == appPid) return false;
    if (packageFilter != null &&
        packageFilter.isNotEmpty &&
        entry.pkg == packageFilter) {
      return false;
    }

    final lowerTag = entry.tag.toLowerCase().trim();

    // 3. Known system noise tags
    if (_knownNoiseTagsLower.contains(lowerTag)) return true;

    // 4. Common subsystem prefixes
    for (final prefix in _noisePrefixes) {
      if (lowerTag.startsWith(prefix)) return true;
    }

    // 5. ART & Zygote background garbage collection chatter
    if (lowerTag == 'art' || lowerTag == 'zygote' || lowerTag == 'zygote64') {
      final lowerMsg = entry.msg.toLowerCase();
      if (lowerMsg.contains('concurrent') ||
          lowerMsg.contains('gc for alloc') ||
          lowerMsg.contains('freed')) {
        return true;
      }
    }

    // 6. Generic chatty throttle summary line
    if (lowerTag == 'chatty' || entry.msg.startsWith('chatty')) {
      return true;
    }

    return false;
  }
}
