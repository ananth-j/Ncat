import 'dart:async';
import 'dart:io';

/// Resolves, downloads, and manages standalone scrcpy installations.
class ScrcpyResolver {
  static const String version = 'v5.0.1';

  /// Resolves the local tools directory for wcat dependencies.
  static Directory getLocalScrcpyDir() {
    String basePath;
    if (Platform.isWindows) {
      final localApp = Platform.environment['LOCALAPPDATA'];
      basePath =
          localApp != null && localApp.isNotEmpty
              ? '$localApp\\wcat\\tools\\scrcpy'
              : '${Platform.environment['USERPROFILE'] ?? '.'}\\.wcat\\tools\\scrcpy';
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      basePath = '$home/Library/Application Support/wcat/tools/scrcpy';
    } else {
      final home = Platform.environment['HOME'] ?? '.';
      basePath = '$home/.local/share/wcat/tools/scrcpy';
    }
    return Directory(basePath);
  }

  /// Optional override for testing or custom binary path.
  static String? executableOverride;

  /// Optional override for testing or custom scrcpy-server jar path.
  static String? serverOverride;

  /// Optional hook for overriding installer during tests.
  static Future<Map<String, dynamic>> Function({
    void Function(String msg)? onStatus,
  })?
  installerOverride;

  /// Locates the scrcpy-server binary/jar on the host system.
  static String? findScrcpyServer() {
    if (serverOverride != null) {
      return serverOverride!.isEmpty ? null : serverOverride;
    }
    if (executableOverride != null && executableOverride!.isEmpty) {
      return null;
    }

    // 1. Environment variable override
    final env = Platform.environment['SCRCPY_SERVER_PATH'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) {
      return env;
    }

    // 2. Local Wcat tools directory
    final localDir = getLocalScrcpyDir();
    if (localDir.existsSync()) {
      try {
        for (final ent in localDir.listSync(recursive: true)) {
          if (ent is File) {
            final name = ent.uri.pathSegments.last.toLowerCase();
            if (name == 'scrcpy-server' || name == 'scrcpy-server.jar') {
              return ent.path;
            }
          }
        }
      } catch (_) {}
    }

    // 3. Beside scrcpy executable if present
    final exe = findScrcpyExecutable();
    if (exe != null) {
      final dir = File(exe).parent;
      for (final name in ['scrcpy-server', 'scrcpy-server.jar']) {
        final serverFile = File('${dir.path}${Platform.pathSeparator}$name');
        if (serverFile.existsSync()) return serverFile.path;
      }
    }

    // 4. Platform-specific locations
    for (final p in [
      '/usr/share/scrcpy/scrcpy-server',
      '/usr/local/share/scrcpy/scrcpy-server',
      '/opt/homebrew/share/scrcpy/scrcpy-server',
      r'C:\scrcpy\scrcpy-server',
      r'C:\Program Files\scrcpy\scrcpy-server',
    ]) {
      if (File(p).existsSync()) return p;
    }

    return null;
  }

  /// Locates the scrcpy binary on the host system.
  /// Checks SCRCPY env var, Wcat local tools directory, system PATH,
  /// and common package manager locations (WinGet, Scoop, Homebrew, etc.).
  static String? findScrcpyExecutable() {
    if (executableOverride != null) {
      return executableOverride!.isEmpty ? null : executableOverride;
    }

    // 1. Environment variable override
    final env = Platform.environment['SCRCPY'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) {
      return env;
    }

    // 2. Local Wcat tools directory
    final localDir = getLocalScrcpyDir();
    if (localDir.existsSync()) {
      final binaryName = Platform.isWindows ? 'scrcpy.exe' : 'scrcpy';
      // Check direct child
      final direct = File(
        '${localDir.path}${Platform.pathSeparator}$binaryName',
      );
      if (direct.existsSync()) return direct.path;

      // Check subdirectories (e.g. scrcpy-win64-v5.0.1/scrcpy.exe)
      try {
        for (final ent in localDir.listSync(recursive: true)) {
          if (ent is File &&
              ent.path.toLowerCase().endsWith(
                Platform.pathSeparator + binaryName,
              )) {
            return ent.path;
          }
        }
      } catch (_) {}
    }

    // 3. System PATH check
    try {
      final cmd = Platform.isWindows ? 'where.exe' : 'which';
      final res = Process.runSync(cmd, ['scrcpy']);
      if (res.exitCode == 0) {
        final lines = res.stdout.toString().split(RegExp(r'[\r\n]+'));
        final valid = lines.firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '',
        );
        if (valid.isNotEmpty && File(valid).existsSync()) {
          return valid;
        }
        return 'scrcpy';
      }
    } catch (_) {}

    // 4. Platform-specific standard locations
    if (Platform.isWindows) {
      for (final p in [
        r'C:\scrcpy\scrcpy.exe',
        r'C:\Program Files\scrcpy\scrcpy.exe',
        r'C:\ProgramData\chocolatey\bin\scrcpy.exe',
      ]) {
        if (File(p).existsSync()) return p;
      }

      // Check WinGet packages directory
      final localApp = Platform.environment['LOCALAPPDATA'];
      if (localApp != null && localApp.isNotEmpty) {
        final wingetDir = Directory('$localApp\\Microsoft\\WinGet\\Packages');
        if (wingetDir.existsSync()) {
          try {
            for (final ent in wingetDir.listSync(recursive: true)) {
              if (ent is File &&
                  ent.path.toLowerCase().endsWith(r'\scrcpy.exe')) {
                return ent.path;
              }
            }
          } catch (_) {}
        }
      }

      // Check Scoop directory
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        final scoopPath =
            '$userProfile\\scoop\\apps\\scrcpy\\current\\scrcpy.exe';
        if (File(scoopPath).existsSync()) return scoopPath;
      }
    } else if (Platform.isMacOS) {
      for (final p in ['/opt/homebrew/bin/scrcpy', '/usr/local/bin/scrcpy']) {
        if (File(p).existsSync()) return p;
      }
    } else if (Platform.isLinux) {
      for (final p in [
        '/usr/bin/scrcpy',
        '/usr/local/bin/scrcpy',
        '/snap/bin/scrcpy',
      ]) {
        if (File(p).existsSync()) return p;
      }
    }

    return null;
  }

  /// Returns the official download URL for the host operating system.
  static String? getDownloadUrl() {
    const base =
        'https://github.com/Genymobile/scrcpy/releases/download/$version';
    if (Platform.isWindows) {
      // 64-bit Windows is standard
      return '$base/scrcpy-win64-$version.zip';
    } else if (Platform.isMacOS) {
      // macOS Apple Silicon (ARM64) or Intel
      final isArm =
          Platform.version.contains('arm64') ||
          Platform.version.contains('aarch64');
      return isArm
          ? '$base/scrcpy-macos-aarch64-$version.tar.gz'
          : '$base/scrcpy-macos-x86_64-$version.tar.gz';
    } else if (Platform.isLinux) {
      return '$base/scrcpy-linux-x86_64-$version.tar.gz';
    }
    return null;
  }

  /// Downloads and extracts the official scrcpy standalone release.
  static Future<Map<String, dynamic>> installScrcpy({
    void Function(String msg)? onStatus,
  }) async {
    if (installerOverride != null) {
      return installerOverride!(onStatus: onStatus);
    }

    final downloadUrl = getDownloadUrl();
    if (downloadUrl == null) {
      return {
        'status': 'error',
        'message':
            'Unsupported operating system for automated scrcpy installation',
      };
    }

    final destDir = getLocalScrcpyDir();
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }

    final ext = downloadUrl.endsWith('.zip') ? '.zip' : '.tar.gz';
    final tempFile = File(
      '${destDir.path}${Platform.pathSeparator}download_temp$ext',
    );

    try {
      onStatus?.call('Downloading scrcpy ($version)...');

      final candidateUrls = [downloadUrl, 'https://gh-proxy.com/$downloadUrl'];

      bool downloaded = false;
      for (final url in candidateUrls) {
        downloaded = await _downloadFile(url, tempFile, onStatus: onStatus);
        if (downloaded) break;
      }

      if (!downloaded) {
        return {
          'status': 'error',
          'message':
              'Failed to download scrcpy from official releases or mirrors. Please check your network connection.',
        };
      }

      onStatus?.call('Extracting scrcpy archive...');
      // Extract using native tar or powershell Expand-Archive
      bool extracted = false;
      try {
        final tarRes = await Process.run('tar', [
          '-xf',
          tempFile.path,
          '-C',
          destDir.path,
        ]);
        if (tarRes.exitCode == 0) {
          extracted = true;
        }
      } catch (_) {}

      if (!extracted && Platform.isWindows) {
        // Fallback to PowerShell Expand-Archive
        final psRes = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          'Expand-Archive -Path "${tempFile.path}" -DestinationPath "${destDir.path}" -Force',
        ]);
        if (psRes.exitCode == 0) {
          extracted = true;
        }
      }

      // Cleanup downloaded archive
      try {
        if (tempFile.existsSync()) tempFile.deleteSync();
      } catch (_) {}

      if (!extracted) {
        return {
          'status': 'error',
          'message': 'Failed to extract scrcpy archive',
        };
      }

      // Verify and resolve extracted binary
      final resolved = findScrcpyExecutable();
      if (resolved != null) {
        // Set execute permissions on POSIX
        if (!Platform.isWindows) {
          try {
            await Process.run('chmod', ['+x', resolved]);
          } catch (_) {}
        }

        onStatus?.call('scrcpy installed successfully.');
        return {'status': 'ok', 'version': version, 'path': resolved};
      } else {
        return {
          'status': 'error',
          'message': 'scrcpy was extracted but binary could not be found',
        };
      }
    } catch (e) {
      try {
        if (tempFile.existsSync()) tempFile.deleteSync();
      } catch (_) {}
      return {'status': 'error', 'message': 'Installation failed: $e'};
    }
  }

  /// Downloads a file with multi-tier fallback: curl -> PowerShell (Windows) -> HttpClient.
  static Future<bool> _downloadFile(
    String url,
    File destination, {
    void Function(String msg)? onStatus,
  }) async {
    // 1. Primary: Native curl (standard on Windows 10/11, macOS, and Linux)
    try {
      final curlCmd = Platform.isWindows ? 'curl.exe' : 'curl';
      final res = await Process.run(curlCmd, [
        '-fSL',
        '--retry',
        '2',
        '-o',
        destination.path,
        url,
      ]);
      if (res.exitCode == 0 &&
          destination.existsSync() &&
          destination.lengthSync() > 1024 * 1024) {
        return true;
      }
    } catch (_) {}

    // 2. Secondary (Windows): PowerShell Invoke-WebRequest
    if (Platform.isWindows) {
      try {
        final psRes = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; '
              'Invoke-WebRequest -Uri "$url" -OutFile "${destination.path}" -UseBasicParsing',
        ]);
        if (psRes.exitCode == 0 &&
            destination.existsSync() &&
            destination.lengthSync() > 1024 * 1024) {
          return true;
        }
      } catch (_) {}
    }

    // 3. Fallback: Dart HttpClient with environment proxy support
    try {
      final client = HttpClient();
      client.findProxy = HttpClient.findProxyFromEnvironment;
      client.connectionTimeout = const Duration(seconds: 20);
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri);
      req.followRedirects = true;
      final res = await req.close();
      if (res.statusCode == HttpStatus.ok) {
        final sink = destination.openWrite();
        await res.pipe(sink);
        client.close();
        if (destination.existsSync() &&
            destination.lengthSync() > 1024 * 1024) {
          return true;
        }
      } else {
        client.close();
      }
    } catch (_) {}

    return false;
  }
}
