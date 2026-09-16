import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';
import '../../core/l10n/app_localizations_x.dart';
import '../../providers/music_providers.dart';
import '../../providers/providers.dart';
import '../../services/lyrics/lyrics_service.dart';
import '../../services/lyrics/lyrics_models.dart';

/// Preview duration before auto-scroll resumes after manual scrolling (matching Metrolist)
const _lyricsPreviewTimeMs = 8000;
const _lyricsAnchorRatio = 0.35; // 35% from the top of the viewport (Metrolist standard)

/// Lyrics view widget for Now Playing screen with Metrolist-style animations
class LyricsView extends ConsumerStatefulWidget {
  final Duration currentPosition;

  const LyricsView({super.key, required this.currentPosition});

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  int _currentLineIndex = -1;
  List<GlobalKey> _lineKeys = [];

  // High-frequency frame ticker for 60/120fps smooth karaoke sweep without rebuilding the full widget tree
  late final Ticker _ticker;
  final ValueNotifier<int> _smoothPositionNotifier = ValueNotifier<int>(0);
  int _lastAudioMs = 0;
  int _lastSyncEpochMs = 0;

  // Auto-scroll management (Metrolist behavior)
  bool _isAutoScrollEnabled = true;
  Timer? _autoScrollResumeTimer;
  bool _isUserScrolling = false;

  @override
  void initState() {
    super.initState();
    _lastAudioMs = widget.currentPosition.inMilliseconds;
    _lastSyncEpochMs = DateTime.now().millisecondsSinceEpoch;
    _smoothPositionNotifier.value = _lastAudioMs;

    _ticker = createTicker((_) {
      final isPlaying = ref.read(isPlayingProvider);
      if (isPlaying) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final elapsed = now - _lastSyncEpochMs;
        final current = _lastAudioMs + elapsed;
        if (_smoothPositionNotifier.value != current) {
          _smoothPositionNotifier.value = current;
          _checkLineIndexChange(current);
        }
      } else if (_smoothPositionNotifier.value != _lastAudioMs) {
        _smoothPositionNotifier.value = _lastAudioMs;
        _checkLineIndexChange(_lastAudioMs);
      }
    });
    _ticker.start();
  }

  void _checkLineIndexChange(int currentPositionMs) {
    final lyricsState = ref.read(lyricsProvider);
    final lines = lyricsState.currentLyrics?.lines;
    if (lines == null || lines.isEmpty) return;

    int newIdx = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].timeInMs <= currentPositionMs) {
        newIdx = i;
      } else {
        break;
      }
    }

    if (newIdx != _currentLineIndex && newIdx >= 0) {
      setState(() {
        _currentLineIndex = newIdx;
      });
      if (_isAutoScrollEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _isAutoScrollEnabled) {
            _scrollToCurrentLine(immediate: false);
          }
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newMs = widget.currentPosition.inMilliseconds;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Estimate where the clock would be now
    final estimatedCurrent = _lastAudioMs + (now - _lastSyncEpochMs);
    final drift = (newMs - estimatedCurrent).abs();

    // Only update sync anchor if there's significant drift (> 80ms) or a seek event
    if (drift > 80 || newMs < _lastAudioMs || newMs - _lastAudioMs > 1000) {
      _lastAudioMs = newMs;
      _lastSyncEpochMs = now;
      _smoothPositionNotifier.value = newMs;
      _checkLineIndexChange(newMs);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _smoothPositionNotifier.dispose();
    _autoScrollResumeTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onUserManualScroll() {
    if (_isAutoScrollEnabled) {
      setState(() {
        _isAutoScrollEnabled = false;
      });
    }
    _autoScrollResumeTimer?.cancel();
    _autoScrollResumeTimer = Timer(
      const Duration(milliseconds: _lyricsPreviewTimeMs),
      () {
        if (mounted && !_isUserScrolling) {
          _resumeAutoScroll();
        }
      },
    );
  }

  void _resumeAutoScroll() {
    _autoScrollResumeTimer?.cancel();
    if (mounted) {
      setState(() {
        _isAutoScrollEnabled = true;
      });
      _scrollToCurrentLine(immediate: false);
    }
  }

  void _scrollToCurrentLine({bool immediate = false}) {
    if (!_scrollController.hasClients ||
        _currentLineIndex < 0 ||
        _currentLineIndex >= _lineKeys.length) {
      return;
    }

    final keyContext = _lineKeys[_currentLineIndex].currentContext;
    if (keyContext != null) {
      Scrollable.ensureVisible(
        keyContext,
        alignment: _lyricsAnchorRatio,
        duration: Duration(milliseconds: immediate ? 0 : 450),
        curve: Curves.easeOutCubic,
      );
    } else {
      final approxOffset = (_currentLineIndex * 60.0).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if (immediate) {
        _scrollController.jumpTo(approxOffset);
      } else {
        _scrollController.animateTo(
          approxOffset,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _scrollController.hasClients &&
            _currentLineIndex < _lineKeys.length) {
          final newContext = _lineKeys[_currentLineIndex].currentContext;
          if (newContext != null) {
            Scrollable.ensureVisible(
              newContext,
              alignment: _lyricsAnchorRatio,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
            );
          }
        }
      });
    }
  }

  /// Seek to a specific position when a lyric line is tapped
  void _seekToLyric(int timeInMs) {
    ref.read(audioPlayerServiceProvider).seek(Duration(milliseconds: timeInMs));
    _resumeAutoScroll();
  }

  @override
  Widget build(BuildContext context) {
    final lyricsState = ref.watch(lyricsProvider);
    final albumColors = ref.watch(albumColorsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? albumColors : albumColors.toLightMode();
    final textColor = colors.onBackground;
    final secondaryColor = textColor.withValues(alpha: 0.5);
    final accentColor = isDark ? albumColors.accentLight : albumColors.accent;

    // Reset scroll and line index when switching tracks or lyrics
    ref.listen(currentTrackProvider, (previous, next) {
      if (previous?.id != next?.id && mounted) {
        setState(() {
          _currentLineIndex = -1;
          _lineKeys = [];
          _isAutoScrollEnabled = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.hasClients) {
            _scrollController.jumpTo(0);
          }
        });
      }
    });

    ref.listen(lyricsProvider, (previous, next) {
      if (previous?.currentLyrics != next.currentLyrics && mounted) {
        setState(() {
          _currentLineIndex = -1;
          _lineKeys = [];
          _isAutoScrollEnabled = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.hasClients) {
            _scrollController.jumpTo(0);
          }
        });
      }
    });

    return _buildLyricsContent(
      context,
      lyricsState,
      isDark,
      textColor,
      secondaryColor,
      accentColor,
    );
  }

  Widget _buildLyricsContent(
    BuildContext context,
    LyricsState lyricsState,
    bool isDark,
    Color textColor,
    Color secondaryColor,
    Color accentColor,
  ) {
    final l10n = context.l10n;
    final status = lyricsState.currentStatus;

    // Loading state
    if (status.state == LyricsProviderState.fetching) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: textColor),
            const SizedBox(height: 16),
            Text(
              l10n.searchingForLyrics,
              style: TextStyle(color: secondaryColor),
            ),
          ],
        ),
      );
    }

    // Error state
    if (status.state == LyricsProviderState.error) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Iconsax.warning_2, size: 48, color: secondaryColor),
            const SizedBox(height: 16),
            Text(
              l10n.failedToLoadLyrics,
              style: TextStyle(color: secondaryColor),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.read(lyricsProvider.notifier).nextProvider(),
              child: Text(l10n.tryAnotherProvider),
            ),
          ],
        ),
      );
    }

    // No lyrics found
    if (status.data == null || !status.data!.hasLyrics) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Iconsax.music, size: 48, color: secondaryColor),
            const SizedBox(height: 16),
            Text(l10n.noLyricsFound, style: TextStyle(color: secondaryColor)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.read(lyricsProvider.notifier).nextProvider(),
              child: Text(l10n.tryAnotherProvider),
            ),
          ],
        ),
      );
    }

    final result = status.data!;

    // Synced lyrics
    if (result.hasSyncedLyrics) {
      return _buildSyncedLyrics(
        result.lines!,
        isDark,
        textColor,
        secondaryColor,
        accentColor,
      );
    }

    // Plain lyrics
    return _buildPlainLyrics(result.lyrics!, isDark, textColor);
  }

  Widget _buildSyncedLyrics(
    List<LyricLine> lines,
    bool isDark,
    Color textColor,
    Color secondaryColor,
    Color accentColor,
  ) {
    if (_lineKeys.length != lines.length) {
      _lineKeys = List.generate(lines.length, (_) => GlobalKey());
      _currentLineIndex = -1;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }

    final currentIdx = _currentLineIndex;

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification &&
                notification.dragDetails != null) {
              _isUserScrolling = true;
              _onUserManualScroll();
            } else if (notification is ScrollUpdateNotification &&
                notification.dragDetails != null) {
              _onUserManualScroll();
            } else if (notification is ScrollEndNotification) {
              _isUserScrolling = false;
            }
            return false;
          },
          child: ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.white,
                Colors.white,
                Colors.transparent,
              ],
              stops: [0.0, 0.12, 0.88, 1.0],
            ).createShader(bounds),
            blendMode: BlendMode.dstIn,
            child: ListView.builder(
              controller: _scrollController,
              cacheExtent: 1500.0,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 96),
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final line = lines[index];
                final isCurrentLine = index == currentIdx;
                final dist = currentIdx >= 0 ? (index - currentIdx).abs() : 999;

                if (line.hasWordSync) {
                  return RepaintBoundary(
                    child: _buildWordSyncLine(
                      line: line,
                      index: index,
                      isCurrentLine: isCurrentLine,
                      dist: dist,
                      textColor: textColor,
                      accentColor: accentColor,
                    ),
                  );
                }

                // Standard line-level animation (Metrolist distance-based scaling)
                return RepaintBoundary(
                  child: _buildLineSyncRow(
                    line: line,
                    index: index,
                    isCurrentLine: isCurrentLine,
                    dist: dist,
                    textColor: textColor,
                    accentColor: accentColor,
                  ),
                );
              },
            ),
          ),
        ),

        // Metrolist-style floating auto-scroll sync button
        Positioned(
          bottom: 16,
          left: 0,
          right: 0,
          child: AnimatedSlide(
            offset: !_isAutoScrollEnabled ? Offset.zero : const Offset(0, 2),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: !_isAutoScrollEnabled ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _resumeAutoScroll,
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Iconsax.refresh,
                            size: 18,
                            color: Colors.white,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Auto-scroll',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Line-level synced row with Metrolist-style distance attenuation
  Widget _buildLineSyncRow({
    required LyricLine line,
    required int index,
    required bool isCurrentLine,
    required int dist,
    required Color textColor,
    required Color accentColor,
  }) {
    final isBg = line.isBackground;
    final fontSize = isBg
        ? 18.0
        : (isCurrentLine ? 28.0 : 22.0);
    final fontWeight = isCurrentLine
        ? FontWeight.bold
        : (dist == 1 ? FontWeight.w500 : FontWeight.w400);

    // Metrolist-style distance opacity curve
    double opacity;
    if (isCurrentLine) {
      opacity = 1.0;
    } else if (dist == 1) {
      opacity = 0.40;
    } else if (dist == 2) {
      opacity = 0.22;
    } else {
      opacity = 0.10;
    }

    final lyricColor = isCurrentLine
        ? accentColor
        : textColor.withValues(alpha: isBg ? 0.35 : opacity);

    return GestureDetector(
      onTap: () => _seekToLyric(line.timeInMs),
      child: AnimatedContainer(
        key: _lineKeys[index],
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        alignment: isBg ? Alignment.center : Alignment.centerLeft,
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: isBg ? 4 : (isCurrentLine ? 10 : 8),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontStyle: isBg ? FontStyle.italic : FontStyle.normal,
            color: lyricColor,
            height: 1.3,
            letterSpacing: isCurrentLine ? -0.4 : 0.0,
            shadows: isCurrentLine
                ? [
                    Shadow(
                      color: accentColor.withValues(alpha: 0.35),
                      blurRadius: 14,
                    ),
                  ]
                : null,
          ),
          child: Text(
            line.text.isEmpty ? '♪' : line.text,
            softWrap: true,
          ),
        ),
      ),
    );
  }

  /// Word-level synced line with Metrolist-style bouncy karaoke animation & isolated word repaints
  Widget _buildWordSyncLine({
    required LyricLine line,
    required int index,
    required bool isCurrentLine,
    required int dist,
    required Color textColor,
    required Color accentColor,
  }) {
    final isBg = line.isBackground;
    final fontSize = isBg
        ? 18.0
        : (isCurrentLine ? 28.0 : 22.0);

    // Distance attenuation for inactive lines
    double lineAlpha;
    if (isCurrentLine) {
      lineAlpha = 1.0;
    } else if (dist == 1) {
      lineAlpha = 0.50;
    } else if (dist == 2) {
      lineAlpha = 0.30;
    } else {
      lineAlpha = 0.15;
    }

    final dimColor = textColor.withValues(alpha: isBg ? 0.35 : lineAlpha);

    return GestureDetector(
      onTap: () => _seekToLyric(line.timeInMs),
      child: Container(
        key: _lineKeys[index],
        alignment: isBg ? Alignment.center : Alignment.centerLeft,
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: isBg ? 4 : (isCurrentLine ? 10 : 8),
        ),
        child: Wrap(
          alignment: isBg ? WrapAlignment.center : WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: line.words!.asMap().entries.map((entry) {
            final wordIdx = entry.key;
            final word = entry.value;
            final isLastWord = wordIdx == line.words!.length - 1;

            return _KaraokeWord(
              word: word,
              isLastWord: isLastWord,
              isCurrentLine: isCurrentLine,
              positionNotifier: _smoothPositionNotifier,
              fontSize: fontSize,
              isBg: isBg,
              textColor: textColor,
              accentColor: accentColor,
              dimColor: dimColor,
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildPlainLyrics(String lyrics, bool isDark, Color textColor) {
    final lines = lyrics
        .split('\n')
        .map((l) => l.trimRight())
        .toList(growable: false);

    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: [0.0, 0.1, 0.9, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final line = lines[index];

          if (line.isEmpty) {
            return const SizedBox(height: 18);
          }

          final isSection = line.startsWith('[') && line.endsWith(']');
          final displayLine = isSection
              ? line.replaceAll(RegExp(r'^[\[\(]+|[\]\)]+$'), '')
              : line;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                displayLine,
                style: TextStyle(
                  fontSize: isSection ? 18 : 22,
                  fontWeight: isSection ? FontWeight.w700 : FontWeight.w400,
                  letterSpacing: isSection ? 0.5 : 0.0,
                  color: textColor.withValues(alpha: isSection ? 0.75 : 0.95),
                  height: 1.35,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Isolated karaoke word widget that repaints smoothly on frame ticks without rebuilding the parent list
class _KaraokeWord extends StatelessWidget {
  final LyricWord word;
  final bool isLastWord;
  final bool isCurrentLine;
  final ValueNotifier<int> positionNotifier;
  final double fontSize;
  final bool isBg;
  final Color textColor;
  final Color accentColor;
  final Color dimColor;

  const _KaraokeWord({
    required this.word,
    required this.isLastWord,
    required this.isCurrentLine,
    required this.positionNotifier,
    required this.fontSize,
    required this.isBg,
    required this.textColor,
    required this.accentColor,
    required this.dimColor,
  });

  @override
  Widget build(BuildContext context) {
    final wordText = isLastWord ? word.text : '${word.text} ';
    final duration = (word.endTimeMs - word.startTimeMs).toDouble();

    // Inactive line: render simple static text with zero overhead
    if (!isCurrentLine) {
      return Text(
        wordText,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w400,
          fontStyle: isBg ? FontStyle.italic : FontStyle.normal,
          color: dimColor,
          height: 1.3,
        ),
      );
    }

    // Active line: listen to positionNotifier and repaint only this word boundary
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: positionNotifier,
        builder: (context, _) {
          final pos = positionNotifier.value;
          final isWordActive =
              pos >= word.startTimeMs && pos < word.endTimeMs;
          final isWordSung = pos >= word.endTimeMs;

          if (isWordActive && duration > 0) {
            final raw = ((pos - word.startTimeMs) / duration).clamp(0.0, 1.0);
            // Smooth Hermite cubic interpolation
            final fillProgress = raw * raw * (3.0 - 2.0 * raw);
            final glowIntensity = fillProgress * fillProgress;
            final scalePop =
                1.0 + (0.04 * math.sin(fillProgress * math.pi));

            return Transform.scale(
              scale: scalePop,
              alignment: Alignment.centerLeft,
              child: ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (bounds) {
                  return LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      accentColor,
                      accentColor,
                      accentColor.withValues(alpha: 0.90),
                      textColor.withValues(alpha: 0.85),
                      textColor.withValues(alpha: 0.85),
                    ],
                    stops: [
                      0.0,
                      (fillProgress * 0.92).clamp(0.0, 1.0),
                      fillProgress,
                      (fillProgress + 0.08).clamp(0.0, 1.0),
                      1.0,
                    ],
                  ).createShader(bounds);
                },
                child: Text(
                  wordText,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w800,
                    fontStyle: isBg ? FontStyle.italic : FontStyle.normal,
                    height: 1.3,
                    letterSpacing: -0.3,
                    shadows: [
                      Shadow(
                        color: accentColor.withValues(
                          alpha: 0.30 + (0.35 * glowIntensity),
                        ),
                        blurRadius: 10 + (14 * glowIntensity),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          if (isWordSung) {
            return Text(
              wordText,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
                fontStyle: isBg ? FontStyle.italic : FontStyle.normal,
                color: accentColor,
                height: 1.3,
                letterSpacing: -0.3,
                shadows: [
                  Shadow(
                    color: accentColor.withValues(alpha: 0.25),
                    blurRadius: 8,
                  ),
                ],
              ),
            );
          }

          // Upcoming words in active line: rendered in bright white for high visibility
          return Text(
            wordText,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              fontStyle: isBg ? FontStyle.italic : FontStyle.normal,
              color: textColor.withValues(alpha: 0.90),
              height: 1.3,
              letterSpacing: -0.2,
            ),
          );
        },
      ),
    );
  }
}

/// Compact lyrics display for mini player or controls area
class LyricsLine extends ConsumerWidget {
  final Duration currentPosition;

  const LyricsLine({super.key, required this.currentPosition});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsState = ref.watch(lyricsProvider);
    final albumColors = ref.watch(albumColorsProvider);
    final textColor = albumColors.onBackground;

    if (!lyricsState.hasLyrics) {
      return const SizedBox.shrink();
    }

    final result = lyricsState.currentLyrics!;

    if (!result.hasSyncedLyrics) {
      return const SizedBox.shrink();
    }

    // Find current line
    final positionMs = currentPosition.inMilliseconds;
    String currentText = '';

    for (final line in result.lines!) {
      if (line.timeInMs <= positionMs) {
        currentText = line.text;
      } else {
        break;
      }
    }

    if (currentText.isEmpty) return const SizedBox.shrink();

    return Text(
      currentText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: textColor.withValues(alpha: 0.7),
        fontSize: 13,
        fontStyle: FontStyle.italic,
      ),
    );
  }
}
