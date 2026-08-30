import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:marquee/marquee.dart';
import 'package:skeletonizer/skeletonizer.dart';
import '../../providers/providers.dart';
import '../../services/download_service.dart';
import '../../services/jams/jams_models.dart';
import '../../models/models.dart';
import '../../services/audio_player_service.dart' as player;
import '../../services/lyrics/lyrics_service.dart';
import '../../services/lyrics/lyrics_models.dart';
import '../../core/design_system/design_system.dart';
import '../../core/services/cache/hive_service.dart';
import '../../core/l10n/app_localizations_x.dart';
import 'artist_screen.dart';
import 'album_screen.dart' show AlbumScreen;
import 'playlist_screen.dart' show PlaylistScreen;
import 'track_options_sheet.dart';
import 'lyrics_view.dart';
import 'ytm_drawer.dart';
import 'jams_panel.dart';
import 'home_shelves.dart' show TrackListShelf;

/// Progress bar widget that only rebuilds on position changes (isolated)
class _NowPlayingProgressBar extends ConsumerWidget {
  final Duration? duration;
  final Color textColor;
  final Color secondaryColor;
  final Color accentColor;
  final bool isCompact;

  const _NowPlayingProgressBar({
    required this.duration,
    required this.textColor,
    required this.secondaryColor,
    required this.accentColor,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position =
        ref.watch(positionStreamProvider).valueOrNull ?? Duration.zero;
    final playerService = ref.watch(audioPlayerServiceProvider);

    final verticalPadding = isCompact ? 2.0 : 16.0;
    final horizontalPadding = isCompact ? 16.0 : 24.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      child: Column(
        children: [
          SliderTheme(
            data: SliderThemeData(
              trackHeight: isCompact ? 3 : 4,
              thumbShape: RoundSliderThumbShape(
                enabledThumbRadius: isCompact ? 4 : 6,
              ),
              overlayShape: RoundSliderOverlayShape(
                overlayRadius: isCompact ? 10 : 14,
              ),
              activeTrackColor: accentColor,
              inactiveTrackColor: textColor.withValues(alpha: 0.2),
              thumbColor: textColor,
              overlayColor: accentColor.withValues(alpha: 0.2),
            ),
            child: Slider(
              value: position.inMilliseconds.toDouble().clamp(
                0,
                (duration?.inMilliseconds ?? 1).toDouble(),
              ),
              min: 0,
              max: (duration?.inMilliseconds ?? 0) > 0
                  ? duration!.inMilliseconds.toDouble()
                  : 1,
              onChanged: (value) {
                playerService.seek(Duration(milliseconds: value.toInt()));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(position),
                  style: TextStyle(fontSize: 12, color: secondaryColor),
                ),
                Text(
                  _formatDuration(duration ?? Duration.zero),
                  style: TextStyle(fontSize: 12, color: secondaryColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

// NOTE: albumColorsProvider is now defined in music_providers.dart for app-wide access

/// Full-screen now playing screen with OuterTune-style dynamic theming
/// NO TRANSLUCENCY - Solid, well-filtered colors only
class NowPlayingScreen extends ConsumerStatefulWidget {
  final VoidCallback? onClose;

  const NowPlayingScreen({super.key, this.onClose});

  /// Show the Now Playing screen with Hero animation support
  static void show(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black54,
        barrierDismissible: true,
        pageBuilder: (context, animation, secondaryAnimation) {
          return const NowPlayingScreen();
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // Slide up from bottom with fade
          final slideAnimation =
              Tween<Offset>(
                begin: const Offset(0.0, 1.0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              );

          return SlideTransition(position: slideAnimation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen>
    with TickerProviderStateMixin {
  static const double _syncedLyricPreviewHeight = 72;
  // Breathing room between the album art and the track title when there is no
  // synced lyric line to occupy that space (plain/no lyrics).
  static const double _noSyncedLyricGap = 20;
  late AnimationController _colorAnimController;
  late TabController _tabController;
  late PageController _pageController;
  late PageController _albumArtPageController; // For swiping album art
  late PageController _stageViewPageController; // For swiping right panel in Stage View
  final GlobalKey<YTMDrawerState> _drawerKey = GlobalKey<YTMDrawerState>();
  AlbumColors _currentColors = AlbumColors.defaultColors();
  AlbumColors _targetColors = AlbumColors.defaultColors();
  String? _lastLyricsTrackId;
  String? _lastRelatedTrackId; // Cache key for related tracks
  Future<WatchRelatedContent>? _relatedContentFuture;
  // ignore: unused_field - reserved for future panel toggle features
  bool _showLyrics = false;
  // ignore: unused_field - reserved for future panel toggle features
  bool _showQueue = false;
  bool _isDrawerExpanded = false; // Track drawer state
  bool _initialColorLoad = true;
  bool _isAlbumSwipeNavigationInProgress = false;
  int? _lastAlbumArtSyncedIndex;
  Orientation? _lastOrientation;
  late AnimationController _heartAnimController;
  late Animation<double> _heartScaleAnimation;
  late Animation<double> _heartOpacityAnimation;
  late ScrollController _queueScrollController;
  bool _hasInitialQueueScrolled = false;

  @override
  void initState() {
    super.initState();
    _colorAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _colorAnimController.addListener(() {
      if (mounted) setState(() {});
    });
    _colorAnimController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _currentColors = _targetColors;
      }
    });

    _queueScrollController = ScrollController();

    // Tab controller for bottom tabs
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        final newIndex = _tabController.index;
        setState(() {
          _showQueue = newIndex == 0;
          _showLyrics = newIndex == 1;
          // index 2 = Related
        });
        if (newIndex == 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToActiveTrack(animate: true);
          });
        }
        if (_pageController.hasClients &&
            _pageController.page?.round() != newIndex) {
          _pageController.animateToPage(
            newIndex,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });

    // Page controller for swiping content
    _pageController = PageController(initialPage: 0);

    // Album art page controller follows actual queue index starting on active index
    final initialQueueIndex =
        ref.read(audioPlayerServiceProvider).currentIndex;
    final startPage = initialQueueIndex >= 0 ? initialQueueIndex : 0;
    _albumArtPageController = PageController(initialPage: startPage);
    _lastAlbumArtSyncedIndex = startPage;

    // Stage view page controller starts on Lyrics (index 1)
    _stageViewPageController = PageController(initialPage: 1);

    // Double tap like heart pop animation controller
    _heartAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _heartScaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.2, end: 1.25)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.25, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.35)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 40,
      ),
    ]).animate(_heartAnimController);

    _heartOpacityAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.0),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0),
        weight: 40,
      ),
    ]).animate(_heartAnimController);
  }

  @override
  void dispose() {
    // This screen is the only place that recolors the system navigation bar
    // (to match the album gradient). The app default is asserted imperatively
    // in main.dart, which doesn't re-run when a route pops, so re-assert it
    // here to keep the album color from lingering after leaving Now Playing.
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: InzxColors.darkBottomNavigation,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    _colorAnimController.dispose();
    _tabController.dispose();
    _pageController.dispose();
    _albumArtPageController.dispose();
    _stageViewPageController.dispose();
    _heartAnimController.dispose();
    _queueScrollController.dispose();
    super.dispose();
  }

  void _scrollToActiveTrack({bool animate = true}) {
    if (!mounted || !_queueScrollController.hasClients) return;

    final queue = ref.read(queueProvider);
    final currentTrack = ref.read(currentTrackProvider);
    if (queue.isEmpty) return;

    int activeIndex = -1;
    if (currentTrack != null) {
      activeIndex = queue.indexWhere((t) => t.id == currentTrack.id);
    }
    if (activeIndex < 0) {
      activeIndex = ref.read(audioPlayerServiceProvider).currentIndex;
    }

    if (activeIndex <= 0) {
      if (_queueScrollController.offset != 0) {
        if (animate) {
          _queueScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        } else {
          _queueScrollController.jumpTo(0);
        }
      }
      return;
    }

    const double itemExtent = 72.0;
    double targetOffset = (activeIndex * itemExtent) - 80.0;
    if (targetOffset < 0) targetOffset = 0;
    if (_queueScrollController.position.hasContentDimensions) {
      targetOffset = targetOffset.clamp(
        0.0,
        _queueScrollController.position.maxScrollExtent,
      );
    }

    if (animate) {
      _queueScrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      _queueScrollController.jumpTo(targetOffset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playbackState = ref.watch(playbackStateProvider);
    final playerService = ref.watch(audioPlayerServiceProvider);
    final albumColors = ref.watch(albumColorsProvider);
    final currentTrack = ref.watch(currentTrackProvider);
    final currentQueueIndex = playerService.currentIndex;

    ref.listen<Track?>(currentTrackProvider, (previous, next) {
      if (next != null && previous?.id != next.id) {
        _hasInitialQueueScrolled = false;
        if (_tabController.index == 0 && _isDrawerExpanded) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToActiveTrack(animate: true);
          });
        }
      }
    });

    final currentOrientation = MediaQuery.of(context).orientation;
    if (_lastOrientation != null && _lastOrientation != currentOrientation) {
      _lastOrientation = currentOrientation;
      _lastAlbumArtSyncedIndex = -1; // Force re-sync of album art controller on orientation change
      final activeTabIndex = _tabController.index;

      if (currentOrientation == Orientation.landscape) {
        // Ensure stage view controller is at the current active tab
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _stageViewPageController.hasClients) {
            _stageViewPageController.jumpToPage(activeTabIndex);
          }
        });
      } else {
        // Returning to portrait: open drawer on the active tab from landscape (e.g., Lyrics)
        _isDrawerExpanded = true;
        _showQueue = activeTabIndex == 0;
        _showLyrics = activeTabIndex == 1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            if (_pageController.hasClients) {
              _pageController.jumpToPage(activeTabIndex);
            }
            if (_tabController.index != activeTabIndex) {
              _tabController.animateTo(activeTabIndex);
            }
            _drawerKey.currentState?.expand();
          }
        });
      }
    } else {
      _lastOrientation = currentOrientation;
    }

    if (currentQueueIndex >= 0 &&
        currentQueueIndex != _lastAlbumArtSyncedIndex) {
      _lastAlbumArtSyncedIndex = currentQueueIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_albumArtPageController.hasClients) return;
        final activePage =
            _safeAlbumArtPage(currentQueueIndex.toDouble()).round();
        if (activePage != currentQueueIndex) {
          _isAlbumSwipeNavigationInProgress = true;
          _albumArtPageController
              .animateToPage(
                currentQueueIndex,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
              )
              .whenComplete(() {
                if (mounted) {
                  _isAlbumSwipeNavigationInProgress = false;
                }
              });
        }
      });
    }

    // First time opening - trigger color extraction immediately & adopt existing colors if non-default
    if (_initialColorLoad && currentTrack != null) {
      _initialColorLoad = false;
      if (!albumColors.isDefault) {
        _currentColors = albumColors;
        _targetColors = albumColors;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(albumColorsProvider.notifier).updateForTrack(currentTrack);
        }
      });
    }

    // Track change for lyrics fetch
    final trackId = currentTrack?.id;
    final isNewTrack = trackId != _lastLyricsTrackId && currentTrack != null;
    if (isNewTrack) {
      _lastLyricsTrackId = trackId;

      // Fetch lyrics for new track
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref
              .read(lyricsProvider.notifier)
              .fetchLyrics(
                LyricsSearchInfo(
                  videoId: currentTrack.id,
                  title: currentTrack.title,
                  artist: currentTrack.artist,
                  album: currentTrack.album,
                  durationSeconds: currentTrack.duration.inSeconds,
                ),
              );
        }
      });
    }

    // Animate when new colors arrive (not default)
    if (albumColors != _targetColors && !albumColors.isDefault) {
      if (_targetColors.isDefault) {
        // Apply immediately if coming from default fallback
        _currentColors = albumColors;
        _targetColors = albumColors;
      } else {
        _currentColors = AlbumColors.lerp(
          _currentColors,
          _targetColors,
          _colorAnimController.value,
        );
        _targetColors = albumColors;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _colorAnimController.forward(from: 0);
          }
        });
      }
    }

    // Calculate animated colors - smooth lerp from current to target
    final animatedColors = AlbumColors.lerp(
      _currentColors,
      _targetColors,
      _colorAnimController.value,
    );

    // Use lighter pastel version in light mode
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? animatedColors : animatedColors.toLightMode();

    final builtWidget = playbackState.when(
      data: (state) {
        if (state.currentTrack == null) {
          return const SizedBox.shrink();
        }

        final track = state.currentTrack!;

        // SOLID colors - no translucency
        final backgroundColor = colors.backgroundPrimary;
        final accentColor = colors.accent;
        final textColor = colors.onBackground;
        final secondaryTextColor = textColor.withValues(alpha: 0.7);

        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;

        if (isLandscape) {
          return Scaffold(
            backgroundColor: backgroundColor,
            body: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    colors.backgroundPrimary,
                    colors.backgroundSecondary,
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
              child: _buildStageView(
                track,
                state,
                playerService,
                textColor,
                secondaryTextColor,
                accentColor,
                colors.surface,
              ),
            ),
          );
        }

        return Scaffold(
          backgroundColor: backgroundColor,
          body: Container(
            // Solid gradient background - NO ALPHA/TRANSLUCENCY
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [colors.backgroundPrimary, colors.backgroundSecondary],
                stops: const [0.0, 1.0],
              ),
            ),
            child: YTMDrawer(
              key: _drawerKey,
              backgroundColor: Colors.transparent,
              surfaceColor: colors.surface,
              surfaceDecoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    colors.backgroundPrimary,
                    colors.backgroundSecondary,
                  ],
                  stops: const [0.0, 1.0],
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
              initiallyExpanded: _isDrawerExpanded,
              onDismiss: () {
                Navigator.of(context).pop();
                widget.onClose?.call();
              },
              onStateChanged: (expanded) {
                setState(() {
                  _isDrawerExpanded = expanded;
                  _showQueue = expanded && _tabController.index == 0;
                  _showLyrics = expanded && _tabController.index == 1;
                });
                if (expanded && _tabController.index == 0) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _scrollToActiveTrack(animate: true);
                  });
                }
              },
              // Position-based tab selection (left=UP NEXT, center=LYRICS, right=RELATED)
              onTabFromPosition: (tabIndex) {
                setState(() {
                  _tabController.animateTo(tabIndex);
                  _showQueue = tabIndex == 0;
                  _showLyrics = tabIndex == 1;
                });
                if (tabIndex == 0) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _scrollToActiveTrack(animate: true);
                  });
                }
                if (_pageController.hasClients) {
                  _pageController.jumpToPage(tabIndex);
                }
              },
              // Now Playing content (shown when collapsed)
              nowPlayingContent: SafeArea(
                top: true,
                bottom: false,
                child: _buildFullAlbumView(
                  track,
                  state,
                  playerService,
                  textColor,
                  secondaryTextColor,
                  accentColor,
                ),
              ),
              // Up Next header (mini player style)
              expandedHeader: _buildMiniPlayerHeader(
                track,
                state,
                playerService,
                textColor,
                accentColor,
              ),
              // Tabs bar - persists between header and content
              tabsWidget: _buildBottomTabs(textColor, accentColor),
              // Tab content - switches based on selected tab
              upNextContent: _buildTabContent(
                textColor,
                secondaryTextColor,
                colors.surface,
              ),
            ),
          ),
        );
      },
      loading: () => Scaffold(
        backgroundColor: isDark ? Colors.black : Theme.of(context).colorScheme.surface,
        body: SafeArea(
          child: Skeletonizer(
            enabled: true,
            enableSwitchAnimation: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                children: [
                  const SizedBox(height: 40),
                  AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey,
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                  const Spacer(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(BoneMock.name),
                    subtitle: Text(BoneMock.words(2)),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: const [
                      Icon(Icons.skip_previous, size: 36),
                      Icon(Icons.play_circle_fill, size: 64),
                      Icon(Icons.skip_next, size: 36),
                    ],
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
      error: (_, _) => const SizedBox.shrink(),
    );

    // Match the system navigation bar with the bottom-most background that the
    // UP NEXT / LYRICS / RELATED rows sit on (bottom of the album gradient).
    final navColor = colors.backgroundSecondary;
    final navIconsDark = navColor.computeLuminance() > 0.5;
    final statusIconsDark =
        colors.backgroundPrimary.computeLuminance() > 0.5;
    final systemOverlay = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness:
          statusIconsDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: navColor,
      systemNavigationBarIconBrightness:
          navIconsDark ? Brightness.dark : Brightness.light,
    );

    return PopScope(
      canPop: !_isDrawerExpanded,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isDrawerExpanded) {
          _drawerKey.collapse();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemOverlay,
        child: builtWidget,
      ),
    );
  }

  /// Full album art view - default when no tab is selected
  Widget _buildFullAlbumView(
    Track track,
    player.PlaybackState state,
    player.AudioPlayerService playerService,
    Color textColor,
    Color secondaryTextColor,
    Color accentColor,
  ) {
    return Column(
      children: [
        // Top bar
        _buildTopBar(track, textColor, secondaryTextColor),

        // Album art
        _buildAlbumArt(track, accentColor),

        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        // Current synced lyric line (shown only when synced lyrics are available)
                        _buildSyncedLyricPreview(textColor),

                        // Track info
                        _buildTrackInfo(
                          track,
                          textColor,
                          secondaryTextColor,
                          accentColor,
                        ),

                        // Progress bar
                        _NowPlayingProgressBar(
                          duration: state.duration,
                          textColor: textColor,
                          secondaryColor: secondaryTextColor,
                          accentColor: accentColor,
                        ),

                        // Controls
                        _buildControls(state, playerService, textColor, accentColor),

                        const Spacer(),

                        // Bottom tabs
                        _buildBottomTabs(textColor, accentColor),

                        SizedBox(height: MediaQuery.of(context).padding.bottom),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Stage View (Landscape Mode): Album Art & Controls on left, Live Lyrics / Queue on right
  Widget _buildStageView(
    Track track,
    player.PlaybackState state,
    player.AudioPlayerService playerService,
    Color textColor,
    Color secondaryTextColor,
    Color accentColor,
    Color surfaceColor,
  ) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Left Panel: Album Art, Track Info, Progress & Controls (30% width)
            SizedBox(
              width: MediaQuery.of(context).size.width * 0.30,
              child: Column(
                children: [
                  // Prominent Large Swipeable Album Art
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(2.0),
                        child: AspectRatio(
                          aspectRatio: 1.0,
                          child: _buildSwipeableAlbumArt(track, accentColor),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 4),

                  // Minimal Track Title & Artist
                  _buildMinimalTrackInfo(track, textColor, secondaryTextColor),

                  // Compact Progress Bar & Duration
                  _NowPlayingProgressBar(
                    duration: state.duration,
                    textColor: textColor,
                    secondaryColor: secondaryTextColor,
                    accentColor: accentColor,
                    isCompact: true,
                  ),

                  // Minimal Controls (Previous, Play/Pause, Next)
                  _buildMinimalControls(
                    state,
                    playerService,
                    textColor,
                    accentColor,
                  ),
                ],
              ),
            ),

            const SizedBox(width: 16),

            // Right Panel: Borderless Swipeable PageView (Up Next / Lyrics [default] / Related)
            Expanded(
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  PageView(
                    controller: _stageViewPageController,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: (index) {
                      if (_tabController.index != index) {
                        _tabController.animateTo(index);
                      }
                      setState(() {
                        _showQueue = index == 0;
                        _showLyrics = index == 1;
                      });
                      if (_pageController.hasClients &&
                          _pageController.page?.round() != index) {
                        _pageController.jumpToPage(index);
                      }
                    },
                    children: [
                      _buildQueueContent(
                        textColor,
                        secondaryTextColor,
                        surfaceColor,
                      ),
                      _buildLyricsView(ref),
                      _buildRelatedContent(textColor, secondaryTextColor),
                    ],
                  ),

                  // Ultra-minimal floating page indicator dots (Up Next • Lyrics • Related)
                  Positioned(
                    top: 4,
                    child: AnimatedBuilder(
                      animation: _stageViewPageController,
                      builder: (context, child) {
                        final page = _stageViewPageController.hasClients
                            ? (_stageViewPageController.page ?? 1.0)
                            : 1.0;

                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: List.generate(3, (index) {
                            final delta = (index - page).abs().clamp(0.0, 1.0);
                            final opacity =
                                (1.0 - (delta * 0.65)).clamp(0.25, 1.0);
                            final width = 18.0 - (delta * 12.0);

                            return Container(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              width: width,
                              height: 4,
                              decoration: BoxDecoration(
                                color: (index == page.round()
                                        ? accentColor
                                        : textColor)
                                    .withValues(alpha: opacity),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            );
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMinimalTrackInfo(
    Track track,
    Color textColor,
    Color secondaryColor,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Title with Marquee auto-scrolling on overflow
        SizedBox(
          height: 20,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final textPainter = TextPainter(
                text: TextSpan(
                  text: track.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                maxLines: 1,
                textDirection: TextDirection.ltr,
              )..layout();

              if (textPainter.width > (constraints.maxWidth - 2)) {
                return Marquee(
                  text: track.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                  scrollAxis: Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  blankSpace: 48.0,
                  velocity: 30.0,
                  pauseAfterRound: const Duration(seconds: 2),
                  startPadding: 0.0,
                  accelerationDuration: const Duration(seconds: 1),
                  accelerationCurve: Curves.linear,
                  decelerationDuration: const Duration(milliseconds: 500),
                  decelerationCurve: Curves.easeOut,
                );
              }

              return Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 2),

        // Artist with Marquee auto-scrolling on overflow
        SizedBox(
          height: 18,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final textPainter = TextPainter(
                text: TextSpan(
                  text: track.artist,
                  style: TextStyle(
                    fontSize: 12,
                    color: secondaryColor,
                  ),
                ),
                maxLines: 1,
                textDirection: TextDirection.ltr,
              )..layout();

              if (textPainter.width > (constraints.maxWidth - 2)) {
                return Marquee(
                  text: track.artist,
                  style: TextStyle(
                    fontSize: 12,
                    color: secondaryColor,
                  ),
                  scrollAxis: Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  blankSpace: 48.0,
                  velocity: 30.0,
                  pauseAfterRound: const Duration(seconds: 2),
                  startPadding: 0.0,
                  accelerationDuration: const Duration(seconds: 1),
                  accelerationCurve: Curves.linear,
                  decelerationDuration: const Duration(milliseconds: 500),
                  decelerationCurve: Curves.easeOut,
                );
              }

              return InkWell(
                onTap: () => ArtistScreen.open(
                  context,
                  artistId: track.artistId,
                  name: track.artist,
                ),
                child: Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: secondaryColor,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMinimalControls(
    player.PlaybackState state,
    player.AudioPlayerService playerService,
    Color textColor,
    Color accentColor,
  ) {
    final isInJam = ref.watch(isInJamSessionProvider);
    final canControl = ref.watch(canControlJamPlaybackProvider);
    final canSkip = !isInJam || canControl;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Previous
        BouncyTouch(
          style: BouncyStyle.button,
          customScale: 0.90,
          onTap: canSkip ? playerService.skipToPrevious : null,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(
              Iconsax.previous,
              color: canSkip ? textColor : textColor.withValues(alpha: 0.3),
              size: 28,
            ),
          ),
        ),
        const SizedBox(width: 16),
        // Play/Pause
        AnimatedPlayPauseButton(
          isPlaying: state.isPlaying,
          onTap: state.isPlaying ? playerService.pause : playerService.play,
          size: 48,
          iconSize: 28,
          backgroundColor: accentColor,
        ),
        const SizedBox(width: 16),
        // Next
        BouncyTouch(
          style: BouncyStyle.button,
          customScale: 0.90,
          onTap: canSkip ? playerService.skipToNext : null,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(
              Iconsax.next,
              color: canSkip ? textColor : textColor.withValues(alpha: 0.3),
              size: 28,
            ),
          ),
        ),
      ],
    );
  }

  /// Mini player header for compact view
  Widget _buildMiniPlayerHeader(
    Track track,
    player.PlaybackState state,
    player.AudioPlayerService playerService,
    Color textColor,
    Color accentColor,
  ) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          // Album art thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: track.thumbnailUrl != null
                  ? CachedNetworkImage(
                      imageUrl: track.thumbnailUrl!,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      color: accentColor.withValues(alpha: 0.3),
                      child: Icon(Iconsax.music, color: textColor),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          // Title and artist
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 22,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final textPainter = TextPainter(
                        text: TextSpan(
                          text: track.title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                        maxLines: 1,
                        textDirection: TextDirection.ltr,
                      )..layout();

                      if (textPainter.width > (constraints.maxWidth - 2)) {
                        return Marquee(
                          text: track.title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                          scrollAxis: Axis.horizontal,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          blankSpace: 48.0,
                          velocity: 30.0,
                          pauseAfterRound: const Duration(seconds: 2),
                          startPadding: 0.0,
                          accelerationDuration: const Duration(seconds: 1),
                          accelerationCurve: Curves.linear,
                          decelerationDuration:
                              const Duration(milliseconds: 500),
                          decelerationCurve: Curves.easeOut,
                        );
                      }

                      return Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 18,
                  child: _buildArtistLink(
                    track,
                    style: TextStyle(
                      fontSize: 13,
                      color: textColor.withValues(alpha: 0.7),
                    ),
                    maxLines: 1,
                    enableMarquee: true,
                  ),
                ),
              ],
            ),
          ),
          // Play/pause button
          AnimatedPlayPauseButton(
            isPlaying: state.isPlaying,
            onTap: state.isPlaying ? playerService.pause : playerService.play,
            size: 40,
            iconSize: 24,
            backgroundColor: accentColor,
          ),
        ],
      ),
    );
  }

  /// Queue content for UP NEXT tab
  Widget _buildQueueContent(
    Color textColor,
    Color secondaryColor,
    Color surfaceColor,
  ) {
    final l10n = context.l10n;
    final queue = ref.watch(queueProvider);
    final currentTrack = ref.watch(currentTrackProvider);
    final isRadioMode = ref.watch(isRadioModeProvider);
    final isFetchingRadio = ref.watch(isFetchingRadioProvider);
    final isInJam = ref.watch(isInJamSessionProvider);
    final jamQueue = ref.watch(jamQueueProvider);
    final isHost = ref.watch(isJamHostProvider);
    final canControlPlayback = ref.watch(canControlJamPlaybackProvider);
    final session = ref.watch(currentJamSessionProvider).valueOrNull;

    // Determine queue label
    String queueLabel;
    IconData? queueIcon;
    if (isInJam) {
      queueLabel = l10n.jamQueue;
      queueIcon = Iconsax.profile_2user;
    } else if (isRadioMode) {
      queueLabel = l10n.radioQueue;
      queueIcon = Icons.all_inclusive;
    } else {
      queueLabel = l10n.queueLabel;
      queueIcon = null;
    }

    // When in jam, show jam queue instead of personal queue
    if (isInJam) {
      return _buildJamQueueContent(
        textColor,
        secondaryColor,
        surfaceColor,
        queueLabel,
        queueIcon,
        jamQueue,
        session,
        isHost,
        canControlPlayback,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with "Playing from" info
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.playingFrom,
                    style: TextStyle(fontSize: 12, color: secondaryColor),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        queueLabel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                      if (queueIcon != null) ...[
                        const SizedBox(width: 6),
                        Icon(queueIcon, size: 16, color: secondaryColor),
                      ],
                    ],
                  ),
                ],
              ),
              // Save button (hide when in jam - jam queue is managed separately)
              if (!isInJam)
                TextButton.icon(
                  onPressed: () =>
                      _showSaveQueueDialog(context, queue, textColor),
                  icon: Icon(
                    Iconsax.music_playlist,
                    size: 18,
                    color: textColor,
                  ),
                  label: Text(l10n.save, style: TextStyle(color: textColor)),
                ),
            ],
          ),
        ),

        // Queue list - ReorderableListView with optimizations
        // Wrap with NotificationListener to detect scroll for infinite radio
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              // Read current state at notification time, not captured build time values
              final currentIsRadioMode = ref.read(isRadioModeProvider);
              final currentIsFetching = ref.read(isFetchingRadioProvider);

              // Check if near bottom and radio mode is on
              if (currentIsRadioMode && !currentIsFetching) {
                final metrics = notification.metrics;
                final remaining = metrics.maxScrollExtent - metrics.pixels;
                // Fetch more when within 500 pixels of bottom
                if (remaining < 500 && metrics.maxScrollExtent > 0) {
                  // Trigger radio fetch
                  ref.read(audioPlayerServiceProvider).fetchMoreRadioTracks();
                }
              }
              return false; // Don't consume the notification
            },
            child: Builder(
              builder: (context) {
                if (!_hasInitialQueueScrolled) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _queueScrollController.hasClients) {
                      _scrollToActiveTrack(animate: false);
                      _hasInitialQueueScrolled = true;
                    }
                  });
                }
                return ReorderableListView.builder(
                  scrollController: _queueScrollController,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              // Add extra item at end for loading indicator when in radio mode
              itemCount: queue.length + (isRadioMode ? 1 : 0),
              // Add prototypeItem for consistent sizing (improves scroll performance)
              proxyDecorator: (child, index, animation) {
                return Material(
                  elevation: 4,
                  color: Colors.transparent,
                  child: child,
                );
              },
              onReorder: (oldIndex, newIndex) {
                // Don't allow reordering the loading indicator
                if (oldIndex >= queue.length || newIndex > queue.length) return;
                ref
                    .read(audioPlayerServiceProvider)
                    .reorderQueue(oldIndex, newIndex);
              },
              itemBuilder: (context, index) {
                // Loading indicator at the end for radio mode
                if (index >= queue.length) {
                  return Container(
                    key: const ValueKey('radio_loading'),
                    height: 72,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: isFetchingRadio
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: secondaryColor,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  l10n.loadingMoreTracks,
                                  style: TextStyle(
                                    color: secondaryColor,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.all_inclusive,
                                  size: 18,
                                  color: secondaryColor,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  l10n.scrollForMore,
                                  style: TextStyle(
                                    color: secondaryColor,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  );
                }

                final track = queue[index];
                final isCurrent = currentTrack?.id == track.id;

                return _buildQueueItemTile(
                  key: ValueKey(track.id + index.toString()),
                  track: track,
                  isCurrent: isCurrent,
                  index: index,
                  textColor: textColor,
                  secondaryColor: secondaryColor,
                  accentColor: ref.watch(albumColorsProvider).accent,
                  onTap: () {
                    ref
                        .read(audioPlayerServiceProvider)
                        .playQueue(queue, startIndex: index);
                  },
                  trailingWidget: ReorderableDragStartListener(
                    index: index,
                    child: Icon(Icons.drag_handle, color: secondaryColor),
                  ),
                );
              },
            );
          },
        ),
      ),
    ),
      ],
    );
  }

  /// Jam queue content - shows jam queue with who added each track
  Widget _buildJamQueueContent(
    Color textColor,
    Color secondaryColor,
    Color surfaceColor,
    String queueLabel,
    IconData? queueIcon,
    List<JamQueueItem> jamQueue,
    JamSession? session,
    bool isHost,
    bool canControlPlayback,
  ) {
    final l10n = context.l10n;
    final currentTrack = ref.watch(currentTrackProvider);
    // Find participant names from session
    String getAddedByName(String oderId) {
      final participant = session?.participants
          .where((p) => p.id == oderId)
          .firstOrNull;
      return participant?.name ?? l10n.someone;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with "Playing from" info
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.playingFrom,
                    style: TextStyle(fontSize: 12, color: secondaryColor),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        queueLabel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                      if (queueIcon != null) ...[
                        const SizedBox(width: 6),
                        Icon(queueIcon, size: 16, color: secondaryColor),
                      ],
                    ],
                  ),
                ],
              ),
              // Show track count
              Text(
                l10n.tracksCount(jamQueue.length),
                style: TextStyle(color: secondaryColor, fontSize: 12),
              ),
            ],
          ),
        ),

        // Jam queue list
        Expanded(
          child: jamQueue.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Iconsax.music, size: 48, color: secondaryColor),
                      const SizedBox(height: 16),
                      Text(
                        l10n.noTracksInQueue,
                        style: TextStyle(color: secondaryColor),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.addSongsToJamQueue,
                        style: TextStyle(color: secondaryColor, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : ReorderableListView.builder(
                  scrollController: _queueScrollController,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: jamQueue.length,
                  onReorder: canControlPlayback
                      ? (oldIndex, newIndex) =>
                            _reorderJamQueue(oldIndex, newIndex)
                      : (_, _) {},
                  buildDefaultDragHandles: false,
                  itemBuilder: (context, index) {
                    final queueItem = jamQueue[index];
                    final jamTrack = queueItem.track;
                    final isCurrent = currentTrack?.id == jamTrack.videoId;
                    final track = Track(
                      id: jamTrack.videoId,
                      title: jamTrack.title,
                      artist: jamTrack.artist,
                      thumbnailUrl: jamTrack.thumbnailUrl,
                      duration: Duration(milliseconds: jamTrack.durationMs),
                    );
                    final addedByName = getAddedByName(queueItem.addedBy);

                    return _buildQueueItemTile(
                      key: ValueKey('jam_${track.id}_$index'),
                      track: track,
                      isCurrent: isCurrent,
                      index: index,
                      textColor: textColor,
                      secondaryColor: secondaryColor,
                      accentColor: ref.watch(albumColorsProvider).accent,
                      onTap: canControlPlayback
                          ? () => _playFromJamQueue(index)
                          : null,
                      subtitleWidget: Text(
                        context.metadataLine([
                          track.artist,
                          l10n.addedByUser(addedByName),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent
                              ? ref
                                  .watch(albumColorsProvider)
                                  .accent
                                  .withValues(alpha: 0.85)
                              : secondaryColor,
                          fontSize: 12,
                        ),
                      ),
                      trailingWidget: canControlPlayback
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    Iconsax.trash,
                                    size: 20,
                                    color: secondaryColor,
                                  ),
                                  onPressed: () =>
                                      _removeFromJamQueue(index),
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: Icon(
                                    Icons.drag_handle,
                                    color: secondaryColor,
                                  ),
                                ),
                              ],
                            )
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Remove a track from the jam queue by index
  void _removeFromJamQueue(int index) async {
    final jamsService = ref.read(jamsServiceProvider);
    if (jamsService != null) {
      await jamsService.removeFromQueue(index);
    }
  }

  /// Play from a specific position in the jam queue
  void _playFromJamQueue(int index) async {
    final jamsService = ref.read(jamsServiceProvider);
    if (jamsService == null) return;

    final jamQueue = ref.read(jamQueueProvider);
    if (index >= jamQueue.length) return;

    // Get the track at this index and remove all items up to and including it
    final queueItem = await jamsService.playFromQueueAt(index);
    if (queueItem == null) return;

    // Convert to Track and play
    final track = Track(
      id: queueItem.track.videoId,
      title: queueItem.track.title,
      artist: queueItem.track.artist,
      thumbnailUrl: queueItem.track.thumbnailUrl,
      duration: Duration(milliseconds: queueItem.track.durationMs),
    );

    // Play the track (host's sync will update participants)
    ref.read(audioPlayerServiceProvider).playTrack(track);
  }

  /// Reorder tracks in the jam queue
  void _reorderJamQueue(int oldIndex, int newIndex) async {
    final jamsService = ref.read(jamsServiceProvider);
    if (jamsService != null) {
      // When dragging down, the newIndex needs adjustment
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      await jamsService.reorderQueue(oldIndex, newIndex);
    }
  }

  Widget _buildQueueItemTile({
    required Key key,
    required Track track,
    required bool isCurrent,
    required int index,
    required Color textColor,
    required Color secondaryColor,
    required Color accentColor,
    required VoidCallback? onTap,
    Widget? subtitleWidget,
    Widget? trailingWidget,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final playbackState = ref.watch(playbackStateProvider).valueOrNull;
    final isPlaying = isCurrent && (playbackState?.isPlaying ?? false);

    return RepaintBoundary(
      key: key,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: Colors.transparent,
            border: isCurrent
                ? Border.all(
                    color: accentColor.withValues(alpha: 0.50),
                    width: 1.0,
                  )
                : null,
          ),
          child: BouncyTouch(
            style: BouncyStyle.card,
            customScale: 0.98,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  // Thumbnail with optional Playing Equalizer overlay
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: track.thumbnailUrl != null
                              ? CachedNetworkImage(
                                  imageUrl: track.thumbnailUrl!,
                                  fit: BoxFit.cover,
                                  memCacheWidth: 96,
                                  memCacheHeight: 96,
                                  fadeInDuration: Duration.zero,
                                  fadeOutDuration: Duration.zero,
                                )
                              : Container(color: Colors.grey.shade800),
                        ),
                      ),
                      if (isCurrent)
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.black.withValues(alpha: 0.45),
                          ),
                          child: Center(
                            child: isPlaying
                                ? _QueuePlayingEqualizerBars(color: accentColor)
                                : Icon(
                                    Icons.play_arrow_rounded,
                                    color: accentColor,
                                    size: 24,
                                  ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),

                  // Track Info (Title & Subtitle)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isCurrent ? accentColor : textColor,
                            fontWeight: isCurrent
                                ? FontWeight.bold
                                : FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 3),
                        subtitleWidget ??
                            Builder(
                              builder: (context) {
                                final state =
                                    ref.watch(playbackStateProvider).valueOrNull;
                                final playerDuration =
                                    isCurrent ? state?.duration : null;
                                final formattedDur = (track.duration.inSeconds > 0)
                                    ? track.formattedDuration
                                    : (playerDuration != null &&
                                            playerDuration.inSeconds > 0
                                        ? _formatDuration(playerDuration)
                                        : null);

                                return Text(
                                  context.trackSubtitle(
                                    track.artist,
                                    formattedDur,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? accentColor.withValues(alpha: 0.85)
                                        : secondaryColor,
                                    fontSize: 12,
                                  ),
                                );
                              },
                            ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Trailing widget (e.g. drag handle or trash button)
                  if (trailingWidget != null) trailingWidget,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Tab content with horizontal swipeable PageView (Up Next / Lyrics / Related)
  Widget _buildTabContent(
    Color textColor,
    Color secondaryColor,
    Color surfaceColor,
  ) {
    return PageView(
      controller: _pageController,
      physics: const BouncingScrollPhysics(),
      onPageChanged: (index) {
        if (_tabController.index != index) {
          _tabController.animateTo(index);
          setState(() {
            _showQueue = index == 0;
            _showLyrics = index == 1;
          });
        }
      },
      children: [
        _buildQueueContent(textColor, secondaryColor, surfaceColor),
        _buildLyricsView(ref),
        _buildRelatedContent(textColor, secondaryColor),
      ],
    );
  }

  /// Related content placeholder
  Widget _buildRelatedContent(Color textColor, Color secondaryColor) {
    final l10n = context.l10n;
    final currentTrack = ref.watch(currentTrackProvider);
    if (currentTrack == null) {
      return Center(
        child: Text(
          l10n.noTrackPlaying,
          style: TextStyle(color: secondaryColor),
        ),
      );
    }

    // Cache the future to prevent re-fetching on every rebuild
    if (_lastRelatedTrackId != currentTrack.id) {
      _lastRelatedTrackId = currentTrack.id;
      _relatedContentFuture = _loadRelatedContent(currentTrack);
    }

    return FutureBuilder<WatchRelatedContent>(
      future: _relatedContentFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Skeletonizer(
            enabled: true,
            enableSwitchAnimation: true,
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Text(
                    BoneMock.words(2),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                ),
                ...List.generate(
                  4,
                  (index) => ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Skeleton.replace(
                      width: 48,
                      height: 48,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.grey,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                    title: Text(BoneMock.name),
                    subtitle: Text(BoneMock.words(2)),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Text(
                    BoneMock.words(3),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                ),
                SizedBox(
                  height: 236,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: 3,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder:
                        (context, index) => SizedBox(
                          width: 140,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Skeleton.replace(
                                width: 140,
                                height: 140,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.grey,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(BoneMock.name),
                              Text(BoneMock.words(2)),
                            ],
                          ),
                        ),
                  ),
                ),
              ],
            ),
          );
        }

        if (snapshot.hasError ||
            !snapshot.hasData ||
            snapshot.data == null ||
            snapshot.data!.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Iconsax.music_filter, size: 48, color: secondaryColor),
                const SizedBox(height: 12),
                Text(
                  l10n.noRelatedTracksFound,
                  style: TextStyle(color: secondaryColor),
                ),
              ],
            ),
          );
        }

        final relatedContent = snapshot.data!;

        return ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
          children: [
            for (final shelf in relatedContent.shelves)
              _buildRelatedShelfSection(shelf, textColor, secondaryColor),
            if (relatedContent.hasAboutSection)
              _buildAboutArtistSection(
                relatedContent,
                textColor,
                secondaryColor,
              ),
          ],
        );
      },
    );
  }

  Future<WatchRelatedContent> _loadRelatedContent(Track currentTrack) async {
    final innerTube = ref.read(innerTubeServiceProvider);
    final relatedTabTitle = context.l10n.relatedTab;

    final relatedContent = await innerTube.getWatchRelatedContent(
      currentTrack.id,
      limitPerShelf: 12,
    );
    if (!relatedContent.isEmpty) {
      return relatedContent;
    }

    final fallbackTracks = await innerTube.getWatchPlaylist(
      currentTrack.id,
      limit: 20,
    );
    final filteredFallback = fallbackTracks
        .where((track) => track.id != currentTrack.id)
        .take(20)
        .toList();
    if (filteredFallback.isNotEmpty) {
      return WatchRelatedContent(
        shelves: [
          HomeShelf(
            id: 'related_fallback_${currentTrack.id}',
            title: relatedTabTitle,
            type: HomeShelfType.unknown,
            items: filteredFallback.map(_trackToShelfItem).toList(),
          ),
        ],
      );
    }

    // Final fallback: search for similar tracks via InnerTube
    try {
      final searchQuery = '${currentTrack.artist} ${currentTrack.title}';
      final searchResults = await innerTube.search(searchQuery);
      final genericTracks = searchResults.tracks
          .where((track) => track.id != currentTrack.id)
          .take(20)
          .toList();

      if (genericTracks.isNotEmpty) {
        return WatchRelatedContent(
          shelves: [
            HomeShelf(
              id: 'related_generic_${currentTrack.id}',
              title: relatedTabTitle,
              type: HomeShelfType.unknown,
              items: genericTracks.map(_trackToShelfItem).toList(),
            ),
          ],
        );
      }
    } catch (_) {
      // Search fallback failed, return empty
    }

    return WatchRelatedContent.empty;
  }

  HomeShelfItem _trackToShelfItem(Track track) {
    return HomeShelfItem(
      id: track.id,
      title: track.title,
      subtitle: track.artist,
      thumbnailUrl: track.thumbnailUrl,
      navigationId: track.id,
      itemType: HomeShelfItemType.song,
      videoId: track.id,
      artistId: track.artistId.isNotEmpty ? track.artistId : null,
    );
  }

  Widget _buildRelatedShelfSection(
    HomeShelf shelf,
    Color textColor,
    Color secondaryColor,
  ) {
    if (_usesHomeQuickPicksLayout(shelf)) {
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: TrackListShelf(
          shelf: shelf,
          isDark: theme.brightness == Brightness.dark,
          colorScheme: theme.colorScheme,
          showPlayButton: false,
          headerHorizontalPadding: 8,
          listHorizontalPadding: 4,
          enableDynamicColors: false,
          showCurrentTrackHighlight: false,
        ),
      );
    }

    final primaryType = _primaryRelatedItemType(shelf);
    final title = _relatedShelfTitle(shelf);
    final titlePrefix = _relatedShelfTitlePrefix(shelf);
    final titleMain = _relatedShelfTitleMain(shelf);
    final showTitle = !_isRedundantRelatedTitle(title);

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: titlePrefix == null
                  ? Text(
                      title,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if ((shelf.headerThumbnailUrl ?? '').isNotEmpty) ...[
                          ClipOval(
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: CachedNetworkImage(
                                imageUrl: shelf.headerThumbnailUrl!,
                                fit: BoxFit.cover,
                                memCacheWidth: 88,
                                memCacheHeight: 88,
                                fadeInDuration: Duration.zero,
                                fadeOutDuration: Duration.zero,
                                errorWidget: (_, _, _) =>
                                    Container(color: Colors.grey.shade800),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                titlePrefix,
                                style: TextStyle(
                                  color: secondaryColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.3,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                titleMain,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          if (primaryType == HomeShelfItemType.song)
            ..._buildRelatedTrackTiles(shelf, textColor, secondaryColor)
          else
            SizedBox(
              height: primaryType == HomeShelfItemType.artist ? 200 : 236,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: shelf.items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (context, index) {
                  final item = shelf.items[index];
                  if (primaryType == HomeShelfItemType.artist) {
                    return _buildRelatedArtistCard(
                      shelf,
                      item,
                      textColor,
                      secondaryColor,
                    );
                  }
                  return _buildRelatedMediaCard(
                    shelf,
                    item,
                    textColor,
                    secondaryColor,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildRelatedTrackTiles(
    HomeShelf shelf,
    Color textColor,
    Color secondaryColor,
  ) {
    final tracks = shelf.items
        .map((item) => item.toTrack())
        .whereType<Track>()
        .toList();

    return List<Widget>.generate(shelf.items.length, (index) {
      final item = shelf.items[index];
      final track = index < tracks.length ? tracks[index] : item.toTrack();
      return RepaintBoundary(
        child: Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 2,
            ),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 52,
                height: 52,
                child: item.thumbnailUrl != null
                    ? CachedNetworkImage(
                        imageUrl: item.thumbnailUrl!,
                        fit: BoxFit.cover,
                        memCacheWidth: 104,
                        memCacheHeight: 104,
                        fadeInDuration: Duration.zero,
                        fadeOutDuration: Duration.zero,
                      )
                    : Container(color: Colors.grey.shade800),
              ),
            ),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              item.subtitle ?? track?.artist ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: secondaryColor, fontSize: 12),
            ),
            onTap: () {
              if (track != null) {
                ref
                    .read(audioPlayerServiceProvider)
                    .playTrack(track, enableRadio: false);
              }
            },
          ),
        ),
      );
    });
  }

  Widget _buildRelatedArtistCard(
    HomeShelf shelf,
    HomeShelfItem item,
    Color textColor,
    Color secondaryColor,
  ) {
    return GestureDetector(
      onTap: () => _handleRelatedItemTap(shelf, item),
      child: SizedBox(
        width: 112,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipOval(
              child: SizedBox(
                width: 112,
                height: 112,
                child: item.thumbnailUrl != null
                    ? CachedNetworkImage(
                        imageUrl: item.thumbnailUrl!,
                        fit: BoxFit.cover,
                      )
                    : Container(color: Colors.grey.shade800),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if ((item.subtitle ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  item.subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondaryColor, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRelatedMediaCard(
    HomeShelf shelf,
    HomeShelfItem item,
    Color textColor,
    Color secondaryColor,
  ) {
    return GestureDetector(
      onTap: () => _handleRelatedItemTap(shelf, item),
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 140,
                height: 140,
                child: item.thumbnailUrl != null
                    ? CachedNetworkImage(
                        imageUrl: item.thumbnailUrl!,
                        fit: BoxFit.cover,
                      )
                    : Container(color: Colors.grey.shade800),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if ((item.subtitle ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  item.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: secondaryColor, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _cleanArtistDescription(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return text;

    // 1. Remove URLs enclosed in parentheses e.g. (https://...) or (http://...)
    text = text.replaceAll(
      RegExp(r'\s*\(\s*https?:\/\/[^\)]+\)', caseSensitive: false),
      '',
    );

    // 2. Remove standalone URLs
    text = text.replaceAll(
      RegExp(r'https?:\/\/\S+', caseSensitive: false),
      '',
    );

    // 3. Remove Wikipedia & Creative Commons / CCA license boilerplate trailers
    text = text.replaceAll(
      RegExp(
        r'[-–—|•]?\s*(?:From\s+)?Wikipedia(?:\s*\(.*?\))?\s*(?:Under\s+.*)?$',
        caseSensitive: false,
        multiLine: true,
      ),
      '',
    );
    text = text.replaceAll(
      RegExp(
        r'[-–—|•]?\s*Under\s+(?:CCA|CC|Creative\s+Commons|the\s+Creative\s+Commons).*$',
        caseSensitive: false,
        multiLine: true,
      ),
      '',
    );
    text = text.replaceAll(
      RegExp(
        r'[-–—|•]?\s*(?:CC-BY-SA|CC\s+BY-SA|Creative\s+Commons\s+Attribution).*$',
        caseSensitive: false,
        multiLine: true,
      ),
      '',
    );

    // 4. Remove empty brackets/parentheses that might remain
    text = text.replaceAll(RegExp(r'\(\s*\)'), '');
    text = text.replaceAll(RegExp(r'\[\s*\]'), '');

    // 5. Clean up redundant spaces and trailing punctuation
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = text.trim();

    // Clean any dangling trailing dashes, pipes, or commas
    text = text.replaceAll(RegExp(r'[\s\-–—|•,]+$'), '');

    return text.trim();
  }

  Widget _buildAboutArtistSection(
    WatchRelatedContent relatedContent,
    Color textColor,
    Color secondaryColor,
  ) {
    final rawDesc = relatedContent.aboutDescription ?? '';
    final cleanedDesc = _cleanArtistDescription(rawDesc);
    if (cleanedDesc.isEmpty) return const SizedBox.shrink();

    final bool hadWikipediaSource =
        rawDesc.toLowerCase().contains('wikipedia') ||
        rawDesc.toLowerCase().contains('cc-by-sa') ||
        rawDesc.toLowerCase().contains('creative commons');

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              relatedContent.aboutTitle ?? context.l10n.aboutArtist,
              style: TextStyle(
                color: textColor,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cleanedDesc,
                  style: TextStyle(
                    color: secondaryColor.withValues(alpha: 0.9),
                    fontSize: 14,
                    height: 1.5,
                    letterSpacing: 0.1,
                  ),
                ),
                if (hadWikipediaSource) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Source: Wikipedia',
                    style: TextStyle(
                      color: secondaryColor.withValues(alpha: 0.5),
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  HomeShelfItemType _primaryRelatedItemType(HomeShelf shelf) {
    final counts = <HomeShelfItemType, int>{};
    for (final item in shelf.items) {
      counts.update(item.itemType, (value) => value + 1, ifAbsent: () => 1);
    }

    return counts.entries.isEmpty
        ? HomeShelfItemType.unknown
        : counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  bool _isRedundantRelatedTitle(String title) {
    final normalizedTitle = title.trim().toLowerCase();
    final normalizedRelated = context.l10n.relatedTab.trim().toLowerCase();
    return normalizedTitle.isEmpty || normalizedTitle == normalizedRelated;
  }

  String _relatedShelfTitle(HomeShelf shelf) {
    final baseTitle = shelf.title.trim().isEmpty
        ? context.l10n.relatedTab
        : shelf.title.trim();
    if (_usesArtistHeaderLayout(shelf)) {
      return '${context.l10n.moreFrom} $baseTitle';
    }

    return baseTitle;
  }

  String? _relatedShelfTitlePrefix(HomeShelf shelf) {
    return _usesArtistHeaderLayout(shelf) ? context.l10n.moreFrom : null;
  }

  String _relatedShelfTitleMain(HomeShelf shelf) {
    return shelf.title.trim().isEmpty
        ? context.l10n.relatedTab
        : shelf.title.trim();
  }

  bool _usesHomeQuickPicksLayout(HomeShelf shelf) {
    final primaryType = _primaryRelatedItemType(shelf);
    return primaryType == HomeShelfItemType.song &&
        !_isRedundantRelatedTitle(shelf.title) &&
        !_usesArtistHeaderLayout(shelf);
  }

  bool _usesArtistHeaderLayout(HomeShelf shelf) {
    final strapline = shelf.strapline?.trim();
    return strapline != null &&
        strapline.isNotEmpty &&
        (shelf.headerThumbnailUrl?.trim().isNotEmpty ?? false) &&
        _primaryRelatedItemType(shelf) != HomeShelfItemType.artist;
  }

  void _handleRelatedItemTap(HomeShelf shelf, HomeShelfItem item) {
    switch (item.itemType) {
      case HomeShelfItemType.playlist:
      case HomeShelfItemType.mix:
        final playlistId = item.playlistId ?? item.navigationId ?? item.id;
        PlaylistScreen.open(
          context,
          playlistId: playlistId,
          title: item.title,
          thumbnailUrl: item.thumbnailUrl,
        );
        break;
      case HomeShelfItemType.album:
        final albumId = item.navigationId ?? item.id;
        AlbumScreen.open(
          context,
          albumId: albumId,
          title: item.title,
          thumbnailUrl: item.thumbnailUrl,
        );
        break;
      case HomeShelfItemType.artist:
        final artistId = item.navigationId ?? item.id;
        ArtistScreen.open(
          context,
          artistId: artistId,
          name: item.title,
          thumbnailUrl: item.thumbnailUrl,
        );
        break;
      default:
        final tracks = shelf.items
            .map((entry) => entry.toTrack())
            .whereType<Track>()
            .toList();
        final index = tracks.indexWhere(
          (track) => track.id == (item.videoId ?? item.id),
        );
        if (tracks.isNotEmpty) {
          ref
              .read(audioPlayerServiceProvider)
              .playQueue(tracks, startIndex: index >= 0 ? index : 0);
        }
    }
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '--:--';
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _showSaveQueueDialog(
    BuildContext context,
    List<Track> queue,
    Color textColor,
  ) {
    final l10n = context.l10n;
    if (queue.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.queueIsEmpty)));
      return;
    }

    final controller = TextEditingController(text: l10n.defaultQueueName);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: backgroundColor,
        title: Text(
          l10n.saveQueueAsPlaylist,
          style: TextStyle(color: textColor),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: textColor),
          decoration: InputDecoration(
            hintText: l10n.playlistName,
            hintStyle: TextStyle(color: textColor.withValues(alpha: 0.5)),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              l10n.cancel,
              style: TextStyle(color: textColor.withValues(alpha: 0.7)),
            ),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                // Create local playlist with all queue tracks
                ref.read(localPlaylistsProvider.notifier).createPlaylist(name);
                final playlists = ref.read(localPlaylistsProvider);
                if (playlists.isNotEmpty) {
                  final newPlaylist = playlists.first;
                  // Add all tracks from queue to playlist
                  for (final track in queue) {
                    ref
                        .read(localPlaylistsProvider.notifier)
                        .addTrackToPlaylist(newPlaylist.id, track);
                  }
                }
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      l10n.savedTracksToPlaylist(queue.length, name),
                    ),
                  ),
                );
              }
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(Track track, Color textColor, Color secondaryColor) {
    final playbackState = ref.watch(playbackStateProvider).valueOrNull;
    final queueTitle = playbackState?.queueTitle;

    final albumName = track.album?.trim();
    final hasAlbumName = albumName != null && albumName.isNotEmpty;
    // Show album name under "NOW PLAYING"; fall back to the queue title.
    final subtitle = hasAlbumName ? albumName : queueTitle?.trim();
    final hasSubtitle = subtitle != null && subtitle.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          BouncyTouch(
            style: BouncyStyle.button,
            customScale: 0.90,
            onTap: () {
              // Use Navigator.pop for Hero animation on close
              Navigator.of(context).pop();
              widget.onClose?.call();
            },
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Icon(Icons.keyboard_arrow_down, color: textColor, size: 32),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.nowPlayingHeader,
                  style: TextStyle(
                    fontSize: hasSubtitle ? 9.5 : 11,
                    fontWeight: FontWeight.w600,
                    color: secondaryColor.withValues(alpha: 0.65),
                    letterSpacing: 1.4,
                  ),
                ),
                if (hasSubtitle) ...[
                  const SizedBox(height: 2),
                  SizedBox(
                    height: 18,
                    width: 220,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final textStyle = TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        );

                        final textPainter = TextPainter(
                          text: TextSpan(
                            text: subtitle.trim(),
                            style: textStyle,
                          ),
                          maxLines: 1,
                          textDirection: TextDirection.ltr,
                        )..layout();

                        if (textPainter.width > constraints.maxWidth) {
                          return Marquee(
                            text: subtitle.trim(),
                            style: textStyle,
                            scrollAxis: Axis.horizontal,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            blankSpace: 36.0,
                            velocity: 25.0,
                            pauseAfterRound: const Duration(seconds: 2),
                            startPadding: 0.0,
                            accelerationDuration: const Duration(seconds: 1),
                            accelerationCurve: Curves.linear,
                            decelerationDuration:
                                const Duration(milliseconds: 500),
                            decelerationCurve: Curves.easeOut,
                          );
                        }

                        return Center(
                          child: Text(
                            subtitle.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: textStyle,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          BouncyTouch(
            style: BouncyStyle.button,
            customScale: 0.90,
            onTap: () {
              final track = ref.read(currentTrackProvider);
              if (track != null) {
                TrackOptionsSheet.show(
                  context,
                  track,
                  hideExploreShare: true,
                );
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Icon(Icons.more_vert, color: textColor),
            ),
          ),
        ],
      ),
    );
  }

  void _handleAlbumArtPageChanged(
    int pageIndex,
    player.AudioPlayerService playerService, {
    required int currentIndex,
    required int queueLength,
  }) {
    if (_isAlbumSwipeNavigationInProgress) return;
    if (pageIndex < 0 || pageIndex >= queueLength) return;
    if (pageIndex == currentIndex) return;
    playerService.skipToIndex(pageIndex);
  }

  Widget _buildAlbumArt(Track track, Color accentColor) {
    final orientation = MediaQuery.of(context).orientation;
    if (_lastOrientation != orientation) {
      _lastAlbumArtSyncedIndex = null;
      _lastOrientation = orientation;
    }

    final lyricsState = ref.watch(lyricsProvider);
    final isFetchingLyrics =
        lyricsState.currentStatus.state == LyricsProviderState.fetching ||
        lyricsState.currentStatus.state == LyricsProviderState.idle;
    final hasSyncedLyrics =
        lyricsState.currentLyrics?.hasSyncedLyrics ?? false;

    // Only expand album art if fetching is complete AND the track does NOT have synced lyrics
    // (i.e. songs with plain text lyrics or no lyrics at all will expand to fill the space cleanly).
    final shouldExpand = !isFetchingLyrics && !hasSyncedLyrics;

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;

        // Expand album art dynamically when synced lyrics preview is not present
        final maxHeightRatio = shouldExpand ? 0.47 : 0.40;
        final maxHeight = screenHeight * maxHeightRatio;

        // Constrain to max height while staying square
        final artSize = math.min(
          screenWidth - (shouldExpand ? 36 : 52),
          maxHeight,
        );

        return AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          height: maxHeight,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: shouldExpand ? 6 : 12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                width: artSize,
                height: artSize,
                child: _buildSwipeableAlbumArt(track, accentColor),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLyricsView(WidgetRef ref) {
    // Get current position for synced lyrics
    final position =
        ref.watch(positionStreamProvider).valueOrNull ?? Duration.zero;
    return LyricsView(currentPosition: position);
  }

  Widget _buildAlbumArtContent(Track? displayTrack, Color accentColor) {
    final localAudioPath = displayTrack?.localFilePath?.trim();
    if (localAudioPath != null && localAudioPath.isNotEmpty) {
      final localCoverFile = File('$localAudioPath.cover.jpg');
      if (localCoverFile.existsSync()) {
        return Image.file(
          localCoverFile,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          errorBuilder: (context, error, stackTrace) {
            return _defaultArt(accentColor);
          },
        );
      }
    }

    final rawThumbnail = displayTrack?.thumbnailUrl?.trim();
    if (rawThumbnail == null || rawThumbnail.isEmpty) {
      return _defaultArt(accentColor);
    }

    final candidates = <String>[];
    final highResFromTrack = displayTrack?.highResThumbnailUrl?.trim();
    if (highResFromTrack != null && highResFromTrack.isNotEmpty) {
      candidates.add(highResFromTrack);
    }

    // Try an upgraded thumbnail first for now playing, then fallback to original.
    final upgradedThumbnail = rawThumbnail.replaceAll('w120-h120', 'w600-h600');
    if (upgradedThumbnail.isNotEmpty) {
      candidates.add(upgradedThumbnail);
    }
    candidates.add(rawThumbnail);

    final uniqueCandidates = <String>[];
    for (final url in candidates) {
      if (url.isEmpty) continue;
      if (!uniqueCandidates.contains(url)) {
        uniqueCandidates.add(url);
      }
    }

    return _buildAlbumArtWithFallback(uniqueCandidates, accentColor);
  }

  Widget _buildAlbumArtWithFallback(List<String> urls, Color accentColor) {
    if (urls.isEmpty) return _defaultArt(accentColor);

    Widget buildAt(int index) {
      if (index >= urls.length) return _defaultArt(accentColor);
      return CachedNetworkImage(
        imageUrl: urls[index],
        fit: BoxFit.cover,
        alignment: Alignment.center,
        placeholder: (context, url) => _defaultArt(accentColor),
        errorWidget: (context, url, error) => buildAt(index + 1),
      );
    }

    return buildAt(0);
  }

  double _safeAlbumArtPage(double fallback) {
    if (!_albumArtPageController.hasClients) return fallback;
    try {
      if (_albumArtPageController.positions.length == 1) {
        return _albumArtPageController.page ?? fallback;
      }
      for (final pos in _albumArtPageController.positions) {
        if (pos.viewportDimension > 0) {
          return pos.pixels / pos.viewportDimension;
        }
      }
    } catch (_) {}
    return fallback;
  }

  void _triggerDoubleTapLike(Track track) {
    final isLiked = ref.read(isTrackLikedProvider(track.id));
    if (!isLiked) {
      _toggleLikeTrack(track);
    }
    _heartAnimController.forward(from: 0.0);
  }

  Widget _buildHeartOverlay() {
    return AnimatedBuilder(
      animation: _heartAnimController,
      builder: (context, child) {
        if (_heartAnimController.isDismissed) return const SizedBox.shrink();
        return IgnorePointer(
          child: Center(
            child: Opacity(
              opacity: _heartOpacityAnimation.value.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: _heartScaleAnimation.value,
                child: Icon(
                  Icons.favorite_rounded,
                  color: Colors.redAccent,
                  size: 96,
                  shadows: [
                    BoxShadow(
                      color: Colors.redAccent.withValues(alpha: 0.7),
                      blurRadius: 36,
                      spreadRadius: 12,
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

  Future<void> _toggleLikeTrack(Track track) async {
    final isLiked = ref.read(isTrackLikedProvider(track.id));
    if (isLiked) {
      ref.read(likedSongsProvider.notifier).unlike(track.id);
      ref
          .read(explicitlyUnlikedIdsProvider.notifier)
          .update((state) => {...state, track.id});
    } else {
      ref.read(likedSongsProvider.notifier).like(track);
      ref
          .read(explicitlyUnlikedIdsProvider.notifier)
          .update((state) => state.where((id) => id != track.id).toSet());
    }

    final authState = ref.read(ytMusicAuthStateProvider);
    if (authState.isLoggedIn) {
      final likeAction = ref.read(ytMusicLikeActionProvider);
      if (isLiked) {
        await likeAction.unlike(track.id);
      } else {
        await likeAction.like(track.id);
      }
      ref.invalidate(ytMusicLikedSongsProvider);
      ref.invalidate(ytMusicPlaylistProvider('LM'));
      ref.invalidate(ytMusicPlaylistProvider('VLLM'));
      ref.invalidate(ytMusicPlaylistProvider('liked'));
      try {
        HiveService.playlistsBox.delete('LM');
        HiveService.playlistsBox.delete('VLLM');
      } catch (_) {}
    } else {
      ref.invalidate(ytMusicPlaylistProvider('LM'));
      ref.invalidate(ytMusicPlaylistProvider('liked'));
    }
  }

  /// Swipeable album art widget for landscape Stage View
  Widget _buildSwipeableAlbumArt(Track track, Color accentColor) {
    final playerService = ref.watch(audioPlayerServiceProvider);
    final queue = playerService.queue;
    final currentIndex = playerService.currentIndex;

    if (queue.length <= 1) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => _triggerDoubleTapLike(track),
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity != null) {
            if (details.primaryVelocity! < -200) {
              playerService.skipToNext();
            } else if (details.primaryVelocity! > 200) {
              playerService.skipToPrevious();
            }
          }
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  // Ambient glow (YT Music style)
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.55),
                    blurRadius: 90,
                    spreadRadius: 24,
                    offset: const Offset(0, 26),
                  ),
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.25),
                    blurRadius: 140,
                    spreadRadius: 40,
                    offset: const Offset(0, 36),
                  ),
                  // Depth shadow for contrast
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 30,
                    spreadRadius: 5,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _buildAlbumArtContent(track, accentColor),
              ),
            ),
            _buildHeartOverlay(),
          ],
        ),
      );
    }

    return PageView.builder(
      controller: _albumArtPageController,
      clipBehavior: Clip.none,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      itemCount: queue.length,
      onPageChanged: (pageIndex) {
        _handleAlbumArtPageChanged(
          pageIndex,
          playerService,
          currentIndex: currentIndex,
          queueLength: queue.length,
        );
      },
      itemBuilder: (context, pageIndex) {
        final displayTrack =
            (pageIndex >= 0 && pageIndex < queue.length)
            ? queue[pageIndex]
            : track;

        return AnimatedBuilder(
          animation: _albumArtPageController,
          builder: (context, child) {
            final fallbackPage = currentIndex >= 0
                ? currentIndex.toDouble()
                : 0.0;
            final page = _safeAlbumArtPage(fallbackPage);
            final delta = (pageIndex - page).abs().clamp(0.0, 1.0);
            final scale = (1.0 - (delta * 0.10)).clamp(0.90, 1.0);
            final opacity = (1.0 - (delta * 0.35)).clamp(0.65, 1.0);

            return Transform.scale(
              scale: scale,
              child: Opacity(
                opacity: opacity,
                child: GestureDetector(
                  onDoubleTap: () => _triggerDoubleTapLike(displayTrack),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            // Ambient glow (YT Music style)
                            BoxShadow(
                              color: accentColor.withValues(alpha: 0.55),
                              blurRadius: 90,
                              spreadRadius: 24,
                              offset: const Offset(0, 26),
                            ),
                            BoxShadow(
                              color: accentColor.withValues(alpha: 0.25),
                              blurRadius: 140,
                              spreadRadius: 40,
                              offset: const Offset(0, 36),
                            ),
                            // Depth shadow for contrast
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 30,
                              spreadRadius: 5,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: _buildAlbumArtContent(
                            displayTrack,
                            accentColor,
                          ),
                        ),
                      ),
                      _buildHeartOverlay(),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSyncedLyricPreview(Color textColor) {
    final lyricsState = ref.watch(lyricsProvider);
    final result = lyricsState.currentLyrics;

    final hasSynced = result != null && result.hasSyncedLyrics;
    final position =
        ref.watch(positionStreamProvider).valueOrNull ?? Duration.zero;
    final positionMs = position.inMilliseconds;
    final lines = hasSynced ? result.lines! : const <LyricLine>[];

    int currentIdx = -1;
    if (hasSynced) {
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].timeInMs <= positionMs) {
          currentIdx = i;
        } else {
          break;
        }
      }
    }

    final text = (currentIdx >= 0 && currentIdx < lines.length)
        ? lines[currentIdx].text.trim()
        : '';
    final bool showLyricLine = hasSynced && text.isNotEmpty;

    return GestureDetector(
      onTap: () {
        _tabController.animateTo(1);
        if (_pageController.hasClients) {
          _pageController.jumpToPage(1);
        }
        _drawerKey.currentState?.expand();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        height: showLyricLine ? _syncedLyricPreviewHeight : _noSyncedLyricGap,
        child: ClipRect(
          child: showLyricLine
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(24, 6, 24, 6),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 380),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, animation) {
                      final curved = CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      );
                      return SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.06),
                          end: Offset.zero,
                        ).animate(curved),
                        child: child,
                      );
                    },
                    layoutBuilder: (currentChild, previousChildren) {
                      return currentChild ?? const SizedBox.shrink();
                    },
                    child: Align(
                      key: ValueKey('lyric_$currentIdx'),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        text,
                        maxLines: 3,
                        overflow: TextOverflow.clip,
                        softWrap: true,
                        textAlign: TextAlign.left,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: textColor.withValues(alpha: 0.90),
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildTrackInfo(
    Track track,
    Color textColor,
    Color secondaryColor,
    Color accentColor, {
    bool isCompact = false,
  }) {
    final titleFontSize = isCompact ? 15.0 : 17.0;
    final titleHeight = isCompact ? 22.0 : 26.0;
    final artistFontSize = isCompact ? 12.0 : 14.0;
    final artistHeight = isCompact ? 18.0 : 22.0;
    final horizontalPadding = isCompact ? 16.0 : 24.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Marquee for long titles
                SizedBox(
                  height: titleHeight,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final textPainter = TextPainter(
                        text: TextSpan(
                          text: track.title,
                          style: TextStyle(
                            fontSize: titleFontSize,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                        maxLines: 1,
                        textDirection: TextDirection.ltr,
                      )..layout();

                      // Only use marquee if text overflows
                      if (textPainter.width > (constraints.maxWidth - 2)) {
                        return Marquee(
                          text: track.title,
                          style: TextStyle(
                            fontSize: titleFontSize,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                          scrollAxis: Axis.horizontal,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          blankSpace: 60.0,
                          velocity: 30.0,
                          pauseAfterRound: const Duration(seconds: 2),
                          startPadding: 0.0,
                          accelerationDuration: const Duration(seconds: 1),
                          accelerationCurve: Curves.linear,
                          decelerationDuration: const Duration(
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
                          fontSize: titleFontSize,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 2),
                // Marquee for long artist names
                SizedBox(
                  height: artistHeight,
                  child: _buildArtistLink(
                    track,
                    style: TextStyle(
                      fontSize: artistFontSize,
                      color: secondaryColor,
                    ),
                    maxLines: 1,
                    enableMarquee: true,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Action Buttons Capsule (Like, Share, Jam)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: textColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: accentColor.withValues(alpha: 0.38),
                width: 1.2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Like button
                Builder(
                  builder: (context) {
                    final isLiked = ref.watch(isTrackLikedProvider(track.id));
                    return BouncyTouch(
                      style: BouncyStyle.heartPop,
                      customScale: 0.85,
                      onTap: () => _toggleLikeTrack(track),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9.0,
                          vertical: 7.0,
                        ),
                        child: Icon(
                          isLiked ? Iconsax.heart5 : Iconsax.heart,
                          color: isLiked
                              ? Colors.red
                              : textColor.withValues(alpha: 0.9),
                          size: 21,
                        ),
                      ),
                    );
                  },
                ),

                const SizedBox(width: 5),
                Container(
                  width: 1,
                  height: 22,
                  color: textColor.withValues(alpha: 0.15),
                ),
                const SizedBox(width: 5),

                // Download / Remove Download button
                Consumer(
                  builder: (context, ref, child) {
                    final l10n = context.l10n;
                    final isDownloaded = ref.watch(
                      isTrackDownloadedProvider(track.id),
                    );
                    final progress = ref.watch(
                      trackDownloadProgressProvider(track.id),
                    );

                    final IconData icon;
                    final Color iconColor;
                    if (isDownloaded) {
                      icon = Icons.download_done_rounded;
                      iconColor = Colors.green;
                    } else if (progress != null) {
                      icon = Icons.downloading_rounded;
                      iconColor = accentColor;
                    } else {
                      icon = Icons.download_rounded;
                      iconColor = textColor.withValues(alpha: 0.9);
                    }

                    return BouncyTouch(
                      style: BouncyStyle.button,
                      customScale: 0.92,
                      onTap: isDownloaded
                          ? () {
                              // Already downloaded - let it stay; no-op.
                            }
                          : progress == null
                              ? () {
                                  ref
                                      .read(downloadManagerProvider.notifier)
                                      .addToQueue(track);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        l10n.downloadStartingTrack(track.title),
                                      ),
                                    ),
                                  );
                                }
                              : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9.0,
                          vertical: 7.0,
                        ),
                        child: progress != null && !isDownloaded
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  value: progress.clamp(0.0, 1.0),
                                  strokeWidth: 2.4,
                                  color: accentColor,
                                  backgroundColor: accentColor.withValues(
                                    alpha: 0.2,
                                  ),
                                ),
                              )
                            : Icon(icon, color: iconColor, size: 20),
                      ),
                    );
                  },
                ),

                const SizedBox(width: 5),
                Container(
                  width: 1,
                  height: 22,
                  color: textColor.withValues(alpha: 0.15),
                ),
                const SizedBox(width: 5),

                // Jams button - listen together
                _buildJamsCompactButton(textColor, accentColor),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArtistLink(
    Track track, {
    required TextStyle style,
    required int maxLines,
    required bool enableMarquee,
  }) {
    final canOpenArtist = track.artistId.isNotEmpty;

    final artistLabel = enableMarquee
        ? LayoutBuilder(
            builder: (context, constraints) {
              final textPainter = TextPainter(
                text: TextSpan(text: track.artist, style: style),
                maxLines: maxLines,
                textDirection: TextDirection.ltr,
              )..layout();

              if (textPainter.width > constraints.maxWidth) {
                return Marquee(
                  text: track.artist,
                  style: style,
                  scrollAxis: Axis.horizontal,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  blankSpace: 60.0,
                  velocity: 30.0,
                  pauseAfterRound: const Duration(seconds: 2),
                  startPadding: 0.0,
                );
              }

              return Text(
                track.artist,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: style,
              );
            },
          )
        : Text(
            track.artist,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: style,
          );

    if (!canOpenArtist) {
      return artistLabel;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openArtist(track),
      child: artistLabel,
    );
  }

  void _openArtist(Track track) {
    if (track.artistId.isEmpty) return;
    ArtistScreen.open(context, artistId: track.artistId, name: track.artist);
  }

  /// Micro-compact Jams button for capsule bar
  Widget _buildJamsCompactButton(Color textColor, Color accentColor) {
    final isInSession = ref.watch(isInJamSessionProvider);
    final session = ref.watch(currentJamSessionProvider).valueOrNull;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            final albumColors = ref.read(albumColorsProvider);
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final bgColor = isDark
                ? albumColors.backgroundPrimary
                : InzxColors.background;
            final txtColor = isDark
                ? albumColors.onBackground
                : InzxColors.textPrimary;
            JamsPanel.show(
              context,
              backgroundColor: bgColor,
              textColor: txtColor,
              accentColor: albumColors.accent,
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 9.0,
              vertical: 7.0,
            ),
            child: Icon(
              Iconsax.profile_2user,
              color: isInSession ? accentColor : textColor.withValues(alpha: 0.9),
              size: 21,
            ),
          ),
        ),
        if (isInSession && session != null)
          Positioned(
            right: 2,
            top: 2,
            child: Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }

  /// Jams icon button with active session indicator
  Widget _buildJamsButton(
    Color textColor,
    Color accentColor, {
    double iconSize = 24,
    BoxConstraints? constraints,
  }) {
    final isInSession = ref.watch(isInJamSessionProvider);
    final session = ref.watch(currentJamSessionProvider).valueOrNull;

    return Stack(
      children: [
        IconButton(
          constraints: constraints,
          padding: constraints != null ? EdgeInsets.zero : null,
          onPressed: () {
            final albumColors = ref.read(albumColorsProvider);
            final isDark = Theme.of(context).brightness == Brightness.dark;
            // Use album colors in dark mode, plain white in light mode
            final bgColor = isDark
                ? albumColors.backgroundPrimary
                : InzxColors.background;
            final txtColor = isDark
                ? albumColors.onBackground
                : InzxColors.textPrimary;
            JamsPanel.show(
              context,
              backgroundColor: bgColor,
              textColor: txtColor,
              accentColor: albumColors.accent,
            );
          },
          icon: Icon(
            Iconsax.profile_2user,
            color: isInSession ? accentColor : textColor.withValues(alpha: 0.9),
            size: iconSize,
          ),
          tooltip: context.l10n.jams,
        ),
        // Active session indicator
        if (isInSession && session != null)
          Positioned(
            right: constraints != null ? 4 : 8,
            top: constraints != null ? 4 : 8,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
          ),
        // Participant count badge
        if (isInSession && session != null && session.participantCount > 1)
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${session.participantCount}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildControls(
    player.PlaybackState state,
    player.AudioPlayerService playerService,
    Color textColor,
    Color accentColor, {
    bool isCompact = false,
  }) {
    // Check if in Jam and has control permission
    final isInJam = ref.watch(isInJamSessionProvider);
    final canControl = ref.watch(canControlJamPlaybackProvider);
    final canSkip =
        !isInJam || canControl; // Can skip if not in Jam or has permission

    final playPauseSize = isCompact ? 52.0 : 72.0;
    final playPauseIconSize = isCompact ? 32.0 : 42.0;
    final skipIconSize = isCompact ? 28.0 : 36.0;
    final modeIconSize = isCompact ? 20.0 : 24.0;
    final horizontalPadding = isCompact ? 12.0 : 24.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: isCompact ? 0 : 0,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Shuffle
          BouncyTouch(
            style: BouncyStyle.button,
            customScale: 0.90,
            onTap: () => playerService.toggleShuffle(),
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Icon(
                Iconsax.shuffle,
                color: state.shuffleEnabled
                    ? accentColor
                    : textColor.withValues(alpha: 0.6),
                size: modeIconSize,
              ),
            ),
          ),
          // Previous
          BouncyTouch(
            style: BouncyStyle.button,
            customScale: 0.90,
            onTap: canSkip ? playerService.skipToPrevious : null,
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Icon(
                Iconsax.previous,
                color: canSkip ? textColor : textColor.withValues(alpha: 0.3),
                size: skipIconSize,
              ),
            ),
          ),
          // Play/Pause - always allowed (sync controller handles it)
          AnimatedPlayPauseButton(
            isPlaying: state.isPlaying,
            onTap: state.isPlaying ? playerService.pause : playerService.play,
            size: playPauseSize,
            iconSize: playPauseIconSize,
            backgroundColor: accentColor,
          ),
          // Next
          BouncyTouch(
            style: BouncyStyle.button,
            customScale: 0.90,
            onTap: canSkip ? playerService.skipToNext : null,
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Icon(
                Iconsax.next,
                color: canSkip ? textColor : textColor.withValues(alpha: 0.3),
                size: skipIconSize,
              ),
            ),
          ),
          // Repeat
          BouncyTouch(
            style: BouncyStyle.button,
            customScale: 0.90,
            onTap: () => playerService.cycleLoopMode(),
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: Icon(
                state.loopMode == LoopMode.one
                    ? Iconsax.repeate_one
                    : Iconsax.repeate_music,
                color: state.loopMode != LoopMode.off
                    ? accentColor
                    : textColor.withValues(alpha: 0.6),
                size: modeIconSize,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// YTM-style bottom tabs with TabBar for animated transitions
  Widget _buildBottomTabs(Color textColor, Color accentColor) {
    // Only show active tab styling when drawer is expanded
    final showActiveState = _isDrawerExpanded;

    return TabBar(
      controller: _tabController,
      // Label color - all same when collapsed, accent when expanded
      labelColor: showActiveState
          ? accentColor
          : textColor.withValues(alpha: 0.6),
      unselectedLabelColor: textColor.withValues(alpha: 0.6),
      // Indicator - transparent when collapsed
      indicatorColor: showActiveState ? accentColor : Colors.transparent,
      indicatorWeight: 2,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: showActiveState ? FontWeight.bold : FontWeight.w500,
        letterSpacing: 0.5,
      ),
      unselectedLabelStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
      ),
      tabs: [
        Tab(text: context.l10n.upNext),
        Tab(text: context.l10n.lyricsTab),
        Tab(text: context.l10n.relatedTab),
      ],
      onTap: (index) {
        setState(() {
          _showQueue = index == 0;
          _showLyrics = index == 1;
          // index 2 = Related
        });
        if (_pageController.hasClients) {
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        }
        // Also expand the drawer when tapping a tab
        _drawerKey.currentState?.expand();
      },
    );
  }

  Widget _defaultArt(Color accentColor) {
    return Container(
      color: accentColor.withValues(alpha: 0.2),
      child: Icon(Iconsax.music, color: accentColor, size: 64),
    );
  }
}

/// Animated 3-bar soundwave equalizer for active playing track in Up Next queue
class _QueuePlayingEqualizerBars extends StatefulWidget {
  final Color color;

  const _QueuePlayingEqualizerBars({required this.color});

  @override
  State<_QueuePlayingEqualizerBars> createState() =>
      __QueuePlayingEqualizerBarsState();
}

class __QueuePlayingEqualizerBarsState extends State<_QueuePlayingEqualizerBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animController,
      builder: (context, child) {
        final val = _animController.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _bar(8 + (val * 10)),
            const SizedBox(width: 2.5),
            _bar(18 - (val * 10)),
            const SizedBox(width: 2.5),
            _bar(6 + (val * 12)),
          ],
        );
      },
    );
  }

  Widget _bar(double height) {
    return Container(
      width: 3,
      height: height.clamp(4.0, 20.0),
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
