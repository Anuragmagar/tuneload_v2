import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Downloads the release APK in-app and hands it to the Android package
/// installer (via [FileProvider]). Falls back gracefully on non-Android
/// platforms, where the caller should keep using the browser URL.
class AppUpdateService {
  AppUpdateService._();

  static final AppUpdateService instance = AppUpdateService._();

  static const MethodChannel _channel = MethodChannel('tuneload/updates');

  static const String apkFileName = 'tuneload.apk';

  /// True when the OS can install packages from this app without prompting
  /// (always true below Android 8).
  Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('canInstallPackages');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the "Install unknown apps" settings page for this app.
  Future<bool> openInstallSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('openInstallSettings');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Full path of the APK used for the active update download.
  Future<String> apkPath() async {
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/apk_updates',
    );
    await dir.create(recursive: true);
    return '${dir.path}/$apkFileName';
  }

  /// Downloads the APK from [downloadUrl] into app-private storage, reporting
  /// progress (0.0-1.0, or null while the size is unknown) through
  /// [onProgress]. Returns the local file path on success.
  Future<String> downloadApk(
    String downloadUrl, {
    required void Function(double? progress) onProgress,
  }) async {
    final path = await apkPath();
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await client.send(request).timeout(
        const Duration(seconds: 30),
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength;
      onProgress(contentLength != null && contentLength > 0 ? 0.0 : null);

      final sink = file.openWrite();
      int received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (contentLength != null && contentLength > 0) {
            onProgress((received / contentLength).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.close();
      }

      if (await file.length() < 1024) {
        await file.delete();
        throw Exception('Invalid APK download');
      }

      return path;
    } finally {
      client.close();
    }
  }

  /// Launches the Android package installer for the APK at [path].
  /// Returns true if the installer activity was started.
  Future<bool> installApk(String path) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('installApk', {
        'path': path,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Convenience: download then install in one call (non-Android safe).
  Future<void> downloadAndInstall(
    String downloadUrl, {
    required void Function(double? progress) onProgress,
    bool skipIfNotInstallable = true,
  }) async {
    if (!Platform.isAndroid) {
      if (skipIfNotInstallable) {
        throw UnsupportedError(
          'In-app updates are only supported on Android',
        );
      }
      return;
    }

    final path = await downloadApk(downloadUrl, onProgress: onProgress);
    final canInstall = await canInstallPackages();
    if (!canInstall) {
      throw const AppUpdateInstallPermissionException();
    }

    await installApk(path);
  }
}

/// Thrown when the OS still requires the user to allow "Install unknown apps".
class AppUpdateInstallPermissionException implements Exception {
  const AppUpdateInstallPermissionException();
}