import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/design_system/design_system.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../services/download_service.dart';
import 'package:marquee/marquee.dart';



/// Custom painter for circular track progress ring around album art
class _CircularTrackProgressPainter extends CustomPainter {
  final double progress; // 0.0 to 1.0
  final Color trackColor;
  final Color progressColor;
  final double strokeWidth;

  _CircularTrackProgressPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
    this.strokeWidth = 2.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // Track background circle
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    canvas.drawCircle(center, radius, trackPaint);

    // Active progress arc
    if (progress > 0) {
      final progressPaint = Paint()
        ..color = progressColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      final startAngle = -math.pi / 2; // 12 o'clock top start
      final sweepAngle = 2 * math.pi * progress.clamp(0.0, 1.0);

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CircularTrackProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// Circular album art with progress ring
class _CircularAlbumArtWithProgress extends ConsumerWidget {
  final Track track;
  final Duration? duration;
  final Color accentColor;
  final Color textColor;

  const _CircularAlbumArtWithProgress({
    required this.track,
    required this.duration,
    required this.accentColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position =
        ref.watch(positionStreamProvider).valueOrNull ?? Duration.zero;

    final progress = (duration?.inMilliseconds ?? 0) > 0
        ? (position.inMilliseconds / duration!.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return SizedBox(
      width: 50,
      height: 50,
      child: CustomPaint(
        painter: _CircularTrackProgressPainter(
          progress: progress,
          trackColor: textColor.withValues(alpha: 0.15),
          progressColor: accentColor,
          strokeWidth: 2.5,
        ),
        child: Center(
          child: Hero(
            tag: 'album-art-${track.id}',
            child: ClipOval(
              child: SizedBox(
                width: 42,
                height: 42,
                child: track.thumbnailUrl != null
                    ? CachedNetworkImage(
                        imageUrl: track.thumbnailUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _defaultArt(accentColor),
                      )
                    : _defaultArt(accentColor),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _defaultArt(Color accentColor) {
    return Container(
      color: accentColor.withValues(alpha: 0.2),
      child: Icon(Iconsax.music, color: accentColor, size: 20),
    );
  }
}

/// Floating glassmorphic capsule MiniPlayer widget
class MusicMiniPlayer extends ConsumerWidget {
  final VoidCallback onTap;

  const MusicMiniPlayer({super.key, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final playbackState = ref.watch(playbackStateProvider);
    final playerService = ref.watch(audioPlayerServiceProvider);
    final albumColors = ref.watch(albumColorsProvider);

    return playbackState.when(
      data: (state) {
        if (state.currentTrack == null) {
          return const SizedBox.shrink();
        }

        final track = state.currentTrack!;
        final hasAlbumColors = !albumColors.isDefault;

        // Accent for progress ring & primary play button
        final accentColor = hasAlbumColors
            ? albumColors.accent
            : colorScheme.primary;

        final List<Color> gradientColors;
        final Color borderColor;
        Color backgroundForText;

        if (isDark) {
          if (hasAlbumColors) {
            gradientColors = [
              albumColors.backgroundPrimary.withValues(alpha: 0.88),
              albumColors.backgroundSecondary.withValues(alpha: 0.82),
            ];
            borderColor = albumColors.accent.withValues(alpha: 0.25);
            backgroundForText = albumColors.backgroundPrimary;
          } else {
            gradientColors = [
              const Color(0xFF1E1E1E).withValues(alpha: 0.90),
              const Color(0xFF121212).withValues(alpha: 0.85),
            ];
            backgroundForText = InzxColors.darkBackground;
            borderColor = Colors.white.withValues(alpha: 0.15);
          }
        } else {
          gradientColors = [
            Colors.white.withValues(alpha: 0.90),
            Colors.white.withValues(alpha: 0.75),
          ];
          borderColor = hasAlbumColors
              ? accentColor.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.8);
          backgroundForText = InzxColors.background;
        }

        final textColors = InzxColors.adaptiveTextColors(backgroundForText);
        final foregroundColor = textColors.primary;
        final secondaryColor = textColors.secondary;

        return BouncyTouch(
          style: BouncyStyle.card,
          customScale: 0.985,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.10),
                    blurRadius: 16,
                    spreadRadius: 1,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(32),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradientColors,
                      ),
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(color: borderColor, width: 1),
                    ),
                    child: Row(
                      children: [
                        // Album Art with Circular Progress Ring
                        _CircularAlbumArtWithProgress(
                          track: track,
                          duration: state.duration,
                          accentColor: accentColor,
                          textColor: foregroundColor,
                        ),
                        const SizedBox(width: 10),

                        // Track Title & Artist
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 18,
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final textPainter = TextPainter(
                                            text: TextSpan(
                                              text: track.title,
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13.5,
                                                color: foregroundColor,
                                              ),
                                            ),
                                            maxLines: 1,
                                            textDirection: TextDirection.ltr,
                                          )..layout();

                                          if (textPainter.width >
                                              (constraints.maxWidth - 2)) {
                                            return Marquee(
                                              text: track.title,
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13.5,
                                                color: foregroundColor,
                                              ),
                                              scrollAxis: Axis.horizontal,
                                              blankSpace: 40.0,
                                              velocity: 28.0,
                                              pauseAfterRound:
                                                  const Duration(seconds: 2),
                                              startPadding: 0.0,
                                              accelerationDuration:
                                                  const Duration(seconds: 1),
                                              accelerationCurve: Curves.linear,
                                              decelerationDuration:
                                                  const Duration(
                                                milliseconds: 500,
                                              ),
                                              decelerationCurve: Curves.easeOut,
                                            );
                                          }

                                          return Text(
                                            track.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13.5,
                                              color: foregroundColor,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              SizedBox(
                                height: 16,
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final textPainter = TextPainter(
                                      text: TextSpan(
                                        text: track.artist,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w500,
                                          color: secondaryColor,
                                        ),
                                      ),
                                      maxLines: 1,
                                      textDirection: TextDirection.ltr,
                                    )..layout();

                                    if (textPainter.width >
                                        (constraints.maxWidth - 2)) {
                                      return Marquee(
                                        text: track.artist,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w500,
                                          color: secondaryColor,
                                        ),
                                        scrollAxis: Axis.horizontal,
                                        blankSpace: 40.0,
                                        velocity: 28.0,
                                        pauseAfterRound:
                                            const Duration(seconds: 2),
                                        startPadding: 0.0,
                                        accelerationDuration:
                                            const Duration(seconds: 1),
                                        accelerationCurve: Curves.linear,
                                        decelerationDuration: const Duration(
                                          milliseconds: 500,
                                        ),
                                        decelerationCurve: Curves.easeOut,
                                      );
                                    }

                                    return Text(
                                      track.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w500,
                                        color: secondaryColor,
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),

                        // 3 Circular Action Controls (Previous, Play/Pause, Next)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildCircularButton(
                              icon: Iconsax.previous,
                              iconSize: 17,
                              onPressed: playerService.skipToPrevious,
                              iconColor: foregroundColor,
                              bgColor: foregroundColor.withValues(alpha: 0.08),
                            ),
                            const SizedBox(width: 6),
                            AnimatedPlayPauseButton(
                              isPlaying: state.isPlaying,
                              onTap: state.isPlaying
                                  ? playerService.pause
                                  : playerService.play,
                              size: 36,
                              iconSize: 20,
                              backgroundColor: accentColor,
                            ),
                            const SizedBox(width: 6),
                            _buildCircularButton(
                              icon: Iconsax.next,
                              iconSize: 17,
                              onPressed: playerService.skipToNext,
                              iconColor: foregroundColor,
                              bgColor: foregroundColor.withValues(alpha: 0.08),
                            ),
                            const SizedBox(width: 4),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }

  Widget _buildCircularButton({
    required IconData icon,
    required double iconSize,
    required VoidCallback onPressed,
    required Color iconColor,
    required Color bgColor,
    double scale = 0.92,
  }) {
    return BouncyTouch(
      style: BouncyStyle.button,
      customScale: scale,
      onTap: onPressed,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: bgColor,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Icon(
            icon,
            color: iconColor,
            size: iconSize,
          ),
        ),
      ),
    );
  }
}
