import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

import '../../core/l10n/app_localizations_x.dart';
import '../../services/app_update_service.dart';

/// Orchestrates the full in-app update: shows a progress dialog while the APK
/// downloads, then (on Android) asks for install permission if needed and
/// launches the package installer. Falls back is up to the caller.
class UpdateProgressDialog {
  static Future<void> show(
    BuildContext context, {
    required String downloadUrl,
    String? version,
    int? assetSize,
  }) async {
    final path = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateProgressDialogContent(
        downloadUrl: downloadUrl,
        version: version,
        assetSize: assetSize,
      ),
    );
    if (path == null || path.isEmpty) return;
    if (!context.mounted) return;

    final service = AppUpdateService.instance;
    var canInstall = await service.canInstallPackages();
    if (!context.mounted) return;
    if (!canInstall) {
      final opened = await _askInstallPermission(context);
      if (!opened) return;
      canInstall = await service.canInstallPackages();
      if (!context.mounted) return;
    }

    if (!canInstall) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.updateInstallPermissionNeeded)),
        );
      }
      return;
    }

    final installed = await service.installApk(path);
    if (!installed && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.updateInstallFailed)),
      );
    }
  }

  static Future<bool> _askInstallPermission(BuildContext context) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.updateInstallPermission),
        content: Text(l10n.updateInstallPermissionDetail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () async {
              await AppUpdateService.instance.openInstallSettings();
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: Text(l10n.openSettings),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class UpdateProgressDialogContent extends StatefulWidget {
  const UpdateProgressDialogContent({
    super.key,
    required this.downloadUrl,
    this.version,
    this.assetSize,
  });

  final String downloadUrl;
  final String? version;
  final int? assetSize;

  @override
  State<UpdateProgressDialogContent> createState() =>
      _UpdateProgressDialogContentState();
}

class _UpdateProgressDialogContentState extends State<UpdateProgressDialogContent>
    with SingleTickerProviderStateMixin {
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    setState(() {
      _error = null;
      _progress = null;
    });
    try {
      final path = await AppUpdateService.instance.downloadApk(
        widget.downloadUrl,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop(path);
    } on Exception {
      if (!mounted) return;
      setState(() => _error = 'failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final primaryColor = colorScheme.primary;
    final l10n = context.l10n;

    final sizeText = _formatSize(widget.assetSize);
    final parts = <String>[
      if (widget.version != null && widget.version!.isNotEmpty)
        widget.version!,
      if (sizeText.isNotEmpty) sizeText,
    ];
    final subtitle = parts.join(' · ');

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1E1E1E).withValues(alpha: 0.92)
                  : Colors.white.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: primaryColor.withValues(alpha: 0.35),
                width: 1.2,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _error != null
                      ? Iconsax.close_circle
                      : Iconsax.arrow_circle_down,
                  size: 48,
                  color: _error != null ? Colors.redAccent : primaryColor,
                ),
                const SizedBox(height: 16),
                Text(
                  _error != null ? l10n.updateDownloadFailed : l10n.updateDownloading,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 6),
                if (_error == null)
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                const SizedBox(height: 20),
                if (_error != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: _startDownload,
                          child: Text(l10n.retry),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: primaryColor,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(l10n.cancel),
                        ),
                      ),
                    ],
                  ),
                ] else
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(
                        value: _progress,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                        color: primaryColor,
                        backgroundColor: primaryColor.withValues(alpha: 0.15),
                      ),
                      const SizedBox(height: 10),
                      if (_progress != null)
                        Text(
                          '${(_progress! * 100).clamp(0, 100).toInt()}%',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: primaryColor,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}