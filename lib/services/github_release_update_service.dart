import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class GithubReleaseInfo {
  const GithubReleaseInfo({
    required this.latestVersion,
    required this.releaseUrl,
    required this.downloadUrl,
    this.body,
    this.releaseName,
    this.assetSize,
  });

  final String latestVersion;
  final String releaseUrl;
  final String downloadUrl;
  final String? body;
  final String? releaseName;

  /// Size of the APK asset in bytes (if available in the GitHub release metadata).
  final int? assetSize;
}

/// Fetches latest release metadata from GitHub (used by What's New dialog).
class GithubReleaseUpdateService {
  GithubReleaseUpdateService._();

  static final GithubReleaseUpdateService instance =
      GithubReleaseUpdateService._();

  static const String _defaultRepo = 'nirmaleeswar30/Inzx';

  static String get _repo {
    final fromEnv = dotenv.env['GITHUB_RELEASE_REPO']?.trim() ?? '';
    return fromEnv.isNotEmpty ? fromEnv : _defaultRepo;
  }

  static String get _latestReleaseApi {
    final fromEnv = dotenv.env['GITHUB_RELEASE_API_URL']?.trim() ?? '';
    if (fromEnv.isNotEmpty) return fromEnv;
    return 'https://api.github.com/repos/$_repo/releases/latest';
  }

  static String get _fallbackReleaseUrl {
    final fromEnv = dotenv.env['GITHUB_RELEASE_PAGE_URL']?.trim() ?? '';
    if (fromEnv.isNotEmpty) return fromEnv;
    return 'https://github.com/$_repo/releases/latest';
  }

  Future<GithubReleaseInfo?> fetchLatestReleaseInfo() async {
    try {
      final response = await http
          .get(
            Uri.parse(_latestReleaseApi),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'TuneLoad-App-Update-Checker',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;

      final tag = (decoded['tag_name'] as String?)?.trim() ?? '';
      final releaseName = (decoded['name'] as String?)?.trim();
      final body = (decoded['body'] as String?)?.trim();
      final htmlUrl = (decoded['html_url'] as String?)?.trim();
      final latestVersion = _normalizeVersion(tag);
      final apkAsset = _pickApkAsset(decoded['assets']);

      return GithubReleaseInfo(
        latestVersion: latestVersion.isNotEmpty ? latestVersion : '1.0.0',
        releaseUrl: (htmlUrl != null && htmlUrl.isNotEmpty)
            ? htmlUrl
            : _fallbackReleaseUrl,
        downloadUrl: apkAsset?.url ?? _fallbackReleaseUrl,
        body: body,
        releaseName: releaseName,
        assetSize: apkAsset?.size,
      );
    } catch (e) {
      if (kDebugMode) {
        print('GitHubRelease: fetchLatestReleaseInfo failed: $e');
      }
      return null;
    }
  }

  String _normalizeVersion(String value) {
    var v = value.trim();
    if (v.isEmpty) return '';
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }
    final plusIndex = v.indexOf('+');
    if (plusIndex >= 0) {
      v = v.substring(0, plusIndex);
    }
    final dashIndex = v.indexOf('-');
    if (dashIndex >= 0) {
      v = v.substring(0, dashIndex);
    }
    return v.trim();
  }

  ({String url, int? size})? _pickApkAsset(dynamic assetsRaw) {
    if (assetsRaw is! List) return null;

    String? primaryUrl;
    int? primarySize;
    String? fallbackUrl;
    int? fallbackSize;

    for (final item in assetsRaw) {
      if (item is! Map<String, dynamic>) continue;
      final name = (item['name'] as String?)?.trim().toLowerCase() ?? '';
      final url = (item['browser_download_url'] as String?)?.trim() ?? '';
      if (url.isEmpty) continue;
      final size = item['size'] as int?;

      if (name == 'tuneload.apk') {
        primaryUrl = url;
        primarySize = size;
      } else if (fallbackUrl == null && name.endsWith('.apk')) {
        fallbackUrl = url;
        fallbackSize = size;
      }
    }

    if (primaryUrl != null) return (url: primaryUrl, size: primarySize);
    if (fallbackUrl != null) return (url: fallbackUrl, size: fallbackSize);
    return null;
  }
}
