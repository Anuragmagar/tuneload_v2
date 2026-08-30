import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Modern glassmorphism About dialog for the TuneLoad drawer
class AboutTuneLoadDialog {
  static Future<void> show(
    BuildContext context, {
    String? version,
  }) async {
    final pkg = await PackageInfo.fromPlatform();
    if (!context.mounted) return;

    const brandRed = Color(0xFFF15656);
    const wine = Color(0xFF832F47);

    await showDialog(
      context: context,
      builder: (dialogContext) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final surface = isDark
            ? const Color(0xFF1E1E1E).withValues(alpha: 0.96)
            : Colors.white.withValues(alpha: 0.97);
        final textPrimary = isDark ? Colors.white : Colors.black87;
        final textSecondary = isDark ? Colors.white60 : Colors.black54;
        final appVersion = version ?? pkg.version;

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 400),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: brandRed.withValues(alpha: 0.35),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: brandRed.withValues(alpha: 0.28),
                      blurRadius: 40,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _AboutHero(
                      brandRed: brandRed,
                      wine: wine,
                      version: appVersion,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: isDark ? 0.06 : 0.04,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: isDark ? 0.10 : 0.08,
                            ),
                          ),
                        ),
                        child: Column(
                          children: [
                            _InfoRow(
                              icon: Iconsax.mobile,
                              label: 'Version',
                              value: 'v$appVersion',
                              accent: brandRed,
                              primary: textPrimary,
                              secondary: textSecondary,
                            ),
                            Divider(
                              height: 1,
                              color: Colors.white.withValues(
                                alpha: isDark ? 0.08 : 0.08,
                              ),
                            ),
                            _InfoRow(
                              icon: Iconsax.box,
                              label: 'Build',
                              value: pkg.buildNumber,
                              accent: brandRed,
                              primary: textPrimary,
                              secondary: textSecondary,
                            ),
                            Divider(
                              height: 1,
                              color: Colors.white.withValues(
                                alpha: isDark ? 0.08 : 0.08,
                              ),
                            ),
                            _InfoRow(
                              icon: Iconsax.user,
                              label: 'Developer',
                              value: 'Anurag',
                              accent: brandRed,
                              primary: textPrimary,
                              secondary: textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => launchUrl(
                                Uri.parse(
                                  'https://anuragmagar.com.np/',
                                ),
                                mode: LaunchMode.externalApplication,
                              ),
                              icon: const Icon(
                                Iconsax.code,
                                size: 16,
                                color: brandRed,
                              ),
                              label: const Text(
                                'Visit Website',
                                style: TextStyle(
                                  color: brandRed,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: brandRed.withValues(alpha: 0.45),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 13),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              style: FilledButton.styleFrom(
                                backgroundColor: brandRed,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 13),
                              ),
                              child: const Text(
                                'Close',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AboutHero extends StatelessWidget {
  const _AboutHero({
    required this.brandRed,
    required this.wine,
    required this.version,
  });

  final Color brandRed;
  final Color wine;
  final String version;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [wine, const Color(0xFFB13A52), brandRed],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: -46,
            right: -36,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.07),
              ),
            ),
          ),
          Positioned(
            bottom: -50,
            left: -30,
            child: Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.05),
              ),
            ),
          ),
          Column(
            children: [
              Container(
                width: 78,
                height: 78,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.25),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.30),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/icon/logo.png',
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: Colors.white.withValues(alpha: 0.15),
                      child: const Icon(
                        Iconsax.music5,
                        size: 36,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'TuneLoad',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Follow your music · v$version',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.80),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    required this.primary,
    required this.secondary,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final Color primary;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 16, color: accent),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(fontSize: 13, color: secondary),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: primary,
            ),
          ),
        ],
      ),
    );
  }
}