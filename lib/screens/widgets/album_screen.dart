import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/design_system/design_system.dart';
import '../../core/l10n/app_localizations_x.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../services/download_service.dart';
import 'track_options_sheet.dart';
import 'mini_player.dart';
import 'artist_page_screen.dart';
import 'now_playing_screen.dart';
import 'package:skeletonizer/skeletonizer.dart';
import '../../services/album_color_extractor.dart';

// Provider for extracting album colors
enum AlbumTrackSort {
  defaultOrder,
  title,
  artist,
  duration,
}

// Provider for extracting album colors
final albumColorsProvider = FutureProvider.family<AlbumColors, String>((
  ref,
  url,
) {
  return AlbumColorExtractor.extractFromUrl(url);
});

// NOTE: We use ytMusicAlbumProvider from ytmusic_providers.dart
// which uses the shared innerTubeServiceProvider singleton.

/// Album detail screen with track listing, in-page search, and customizable view styles
class AlbumScreen extends ConsumerStatefulWidget {
  final String albumId;
  final String? albumTitle;
  final String? thumbnailUrl;

  const AlbumScreen({
    super.key,
    required this.albumId,
    this.albumTitle,
    this.thumbnailUrl,
  });

  static void open(
    BuildContext context, {
    required String albumId,
    String? title,
    String? thumbnailUrl,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AlbumScreen(
          albumId: albumId,
          albumTitle: title,
          thumbnailUrl: thumbnailUrl,
        ),
      ),
    );
  }

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  bool _isSearching = false;
  String _searchQuery = '';
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  bool _isCompactView = false;
  AlbumTrackSort _sortOption = AlbumTrackSort.defaultOrder;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  List<Track> _getSortedTracks(List<Track> tracks) {
    final list = List<Track>.from(tracks);
    switch (_sortOption) {
      case AlbumTrackSort.defaultOrder:
        return list;
      case AlbumTrackSort.title:
        list.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        return list;
      case AlbumTrackSort.artist:
        list.sort(
          (a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
        );
        return list;
      case AlbumTrackSort.duration:
        list.sort((a, b) => b.duration.compareTo(a.duration));
        return list;
    }
  }

  String _getSortLabel(AlbumTrackSort sort, AppLocalizations l10n) {
    switch (sort) {
      case AlbumTrackSort.defaultOrder:
        return 'Default';
      case AlbumTrackSort.title:
        return l10n.name;
      case AlbumTrackSort.artist:
        return l10n.artistLabel;
      case AlbumTrackSort.duration:
        return l10n.duration;
    }
  }

  void _showSortBottomSheet<T>({
    required T currentValue,
    required List<(T, String, IconData)> options,
    required ValueChanged<T> onSelected,
    required bool isDark,
    required Color accentColor,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Consumer(
          builder: (context, refConsumer, child) {
            final liveAccent = refConsumer.watch(effectiveAccentColorProvider);
            final sheetBg = isDark
                ? const Color(0xFF141414).withValues(alpha: 0.92)
                : Colors.white.withValues(alpha: 0.95);
            final textColor = isDark ? Colors.white : Colors.black87;
            final secondaryColor = textColor.withValues(alpha: 0.55);

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Container(
                      decoration: BoxDecoration(
                        color: sheetBg,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: liveAccent.withValues(alpha: 0.22),
                          width: 1.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 32,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Drag handle
                            Center(
                              child: Container(
                                width: 36,
                                height: 4,
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: textColor.withValues(alpha: 0.25),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),

                            // Header
                            Padding(
                              padding: const EdgeInsets.only(left: 6, bottom: 8),
                              child: Text(
                                'SORT BY',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                  color: secondaryColor,
                                ),
                              ),
                            ),

                            // Options list
                            Column(
                              children: options.map((opt) {
                                final isSelected = opt.$1 == currentValue;

                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: InkWell(
                                    onTap: () {
                                      Navigator.pop(context);
                                      onSelected(opt.$1);
                                    },
                                    borderRadius: BorderRadius.circular(16),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 42,
                                            height: 42,
                                            decoration: BoxDecoration(
                                              color: (isSelected
                                                      ? liveAccent
                                                      : (isDark
                                                          ? Colors.white
                                                          : Colors.black))
                                                  .withValues(
                                                    alpha: isDark ? 0.12 : 0.07,
                                                  ),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              border: Border.all(
                                                color: (isSelected
                                                        ? liveAccent
                                                        : (isDark
                                                            ? Colors.white
                                                            : Colors.black))
                                                    .withValues(
                                                      alpha: isDark
                                                          ? 0.18
                                                          : 0.10,
                                                    ),
                                                width: 0.8,
                                              ),
                                            ),
                                            child: Icon(
                                              opt.$3,
                                              size: 20,
                                              color: isSelected
                                                  ? liveAccent
                                                  : (isDark
                                                      ? Colors.white70
                                                      : Colors.black87),
                                            ),
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Text(
                                              opt.$2,
                                              style: TextStyle(
                                                fontSize: 15,
                                                fontWeight: isSelected
                                                    ? FontWeight.w600
                                                    : FontWeight.w500,
                                                color: isSelected
                                                    ? liveAccent
                                                    : textColor,
                                              ),
                                            ),
                                          ),
                                          if (isSelected)
                                            Icon(
                                              Icons.check_rounded,
                                              size: 20,
                                              color: liveAccent,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 6),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildControlBar(
    bool isDark,
    Color themeColor,
    AppLocalizations l10n,
    int trackCount,
  ) {
    final sortOptions = [
      (
        AlbumTrackSort.defaultOrder,
        'Default',
        Icons.format_list_numbered_rounded,
      ),
      (
        AlbumTrackSort.title,
        l10n.name,
        Icons.sort_by_alpha_rounded,
      ),
      (
        AlbumTrackSort.artist,
        l10n.artistLabel,
        Icons.person_rounded,
      ),
      (
        AlbumTrackSort.duration,
        l10n.duration,
        Icons.timer_outlined,
      ),
    ];

    final fg = isDark ? Colors.white : Colors.black;
    final surface = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.07);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: surface,
              border: Border.all(color: fg.withValues(alpha: 0.08), width: 1),
            ),
            child: Row(
              children: [
                if (trackCount > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '$trackCount ${trackCount == 1 ? "track" : "tracks"}',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        color: fg.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                const Spacer(),
                // Sort chip
                InkWell(
                  onTap: () {
                    _showSortBottomSheet<AlbumTrackSort>(
                      currentValue: _sortOption,
                      options: sortOptions,
                      onSelected: (newSort) =>
                          setState(() => _sortOption = newSort),
                      isDark: isDark,
                      accentColor: themeColor,
                    );
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: themeColor.withValues(
                        alpha: isDark ? 0.2 : 0.14,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.swap_vert_rounded,
                          size: 16,
                          color: isDark ? themeColor : themeColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _getSortLabel(_sortOption, l10n),
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: isDark ? themeColor : themeColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Segmented view toggle
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _viewTab(
                        icon: Icons.view_headline_rounded,
                        label: 'Compact',
                        active: _isCompactView,
                        fg: fg,
                        themeColor: themeColor,
                        onTap: () =>
                            setState(() => _isCompactView = true),
                      ),
                      _viewTab(
                        icon: Icons.view_list_rounded,
                        label: 'Detailed',
                        active: !_isCompactView,
                        fg: fg,
                        themeColor: themeColor,
                        onTap: () =>
                            setState(() => _isCompactView = false),
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
  }

  Widget _viewTab({
    required IconData icon,
    required String label,
    required bool active,
    required Color fg,
    required Color themeColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: active ? themeColor.withValues(alpha: 0.22) : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: active
                  ? themeColor
                  : fg.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active
                    ? themeColor
                    : fg.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataPill(String text, bool isDark, {IconData? icon}) {
    final fg = isDark ? Colors.white : Colors.black;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: icon != null ? 10 : 12,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: fg.withValues(alpha: 0.14),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg.withValues(alpha: 0.55)),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: fg.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground(
    BuildContext context,
    String? imageUrl,
    Color themeColor,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl != null)
            CachedNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              memCacheWidth: 100,
              color: (isDark ? Colors.black : Colors.white).withValues(
                alpha: isDark ? 0.5 : 0.5,
              ),
              colorBlendMode: isDark ? BlendMode.darken : BlendMode.lighten,
            ),
          // Accent glow radiating from behind the album art
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 1.2,
                center: const Alignment(-0.75, -0.85),
                colors: [
                  themeColor.withValues(alpha: 0.5),
                  themeColor.withValues(alpha: 0.18),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        themeColor.withValues(alpha: 0.28),
                        Colors.black.withValues(alpha: 0.6),
                        Colors.black,
                      ]
                    : [
                        themeColor.withValues(alpha: 0.16),
                        colorScheme.surface.withValues(alpha: 0.8),
                        colorScheme.surface,
                      ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          // Bottom scrim keeps the track list legible over the artwork
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: isDark ? 0.5 : 0.2),
                ],
                stops: const [0.55, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final albumAsync = ref.watch(ytMusicAlbumProvider(widget.albumId));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final playerService = ref.read(audioPlayerServiceProvider);

    return Scaffold(
      backgroundColor: isDark ? Colors.black : colorScheme.surface,
      body: albumAsync.when(
        loading: () => _buildLoadingState(
          widget.albumTitle,
          widget.thumbnailUrl,
          isDark,
          colorScheme,
          l10n,
        ),
        error: (e, stack) =>
            _buildErrorState(l10n.errorWithMessage(e.toString()), isDark),
        data: (album) {
          if (album == null) {
            return _buildErrorState(l10n.albumNotFound, isDark);
          }
          return _buildContent(
            context,
            ref,
            album,
            isDark,
            colorScheme,
            playerService,
          );
        },
      ),
    );
  }

  Widget _buildLoadingState(
    String? title,
    String? thumbnail,
    bool isDark,
    ColorScheme colorScheme,
    AppLocalizations l10n,
  ) {
    return _buildContent(
      null,
      null,
      Album(
        id: widget.albumId,
        title: title ?? l10n.loading,
        thumbnailUrl: thumbnail,
        artist: l10n.loading,
        tracks: [],
      ),
      isDark,
      colorScheme,
      null,
      isLoading: true,
    );
  }

  Widget _buildErrorState(String error, bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Iconsax.warning_2,
            size: 48,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
          const SizedBox(height: 16),
          Text(
            error,
            textAlign: TextAlign.center,
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black87),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext? context,
    WidgetRef? ref,
    Album album,
    bool isDark,
    ColorScheme colorScheme,
    dynamic playerService, {
    bool isLoading = false,
  }) {
    final rawTracks = album.tracks ?? [];
    final allTracks = rawTracks.map((t) {
      return t.copyWith(
        artist: (t.artist.isEmpty || t.artist == 'Unknown Artist')
            ? album.artist
            : t.artist,
        album: (t.album == null ||
                t.album!.isEmpty ||
                t.album == 'Unknown Album')
            ? album.title
            : t.album,
        albumId: (t.albumId == null || t.albumId!.isEmpty)
            ? album.id
            : t.albumId,
        thumbnailUrl: (t.thumbnailUrl == null || t.thumbnailUrl!.isEmpty)
            ? album.thumbnailUrl
            : t.thumbnailUrl,
      );
    }).toList();

    // Extract year from album.year or description/subtitle
    String? year;
    if (album.year != null && album.year!.isNotEmpty) {
      year = album.year;
    }

    // Track count
    final trackCount = allTracks.length;

    // Total duration formatting
    int totalDurationSeconds = 0;
    for (final t in allTracks) {
      totalDurationSeconds += t.duration.inSeconds;
    }
    String totalTimeFormatted = '';
    if (totalDurationSeconds > 0) {
      final hours = totalDurationSeconds ~/ 3600;
      final minutes = (totalDurationSeconds % 3600) ~/ 60;
      if (hours > 0) {
        if (minutes > 0) {
          totalTimeFormatted = '$hours hr $minutes min';
        } else {
          totalTimeFormatted = '$hours hr';
        }
      } else {
        totalTimeFormatted = '$minutes min';
      }
    }

    // Filter tracks based on search query
    final searchedTracks = _searchQuery.isEmpty
        ? allTracks
        : allTracks
              .where(
                (t) =>
                    t.title.toLowerCase().contains(
                      _searchQuery.toLowerCase(),
                    ) ||
                    t.artist.toLowerCase().contains(_searchQuery.toLowerCase()),
              )
              .toList();

    // Sort tracks
    final displayTracks = _getSortedTracks(searchedTracks);

    // Low res for background (performance), High res for foreground
    final lowResThumb = album.thumbnailUrl;
    final highResThumb =
        album.highResThumbnailUrl?.replaceAll('w120-h120', 'w600-h600') ??
        album.thumbnailUrl?.replaceAll('w120-h120', 'w600-h600');

    // Extract colors from the high res thumbnail (or low res)
    final colorSource = lowResThumb ?? highResThumb;
    final albumColors = ref != null && colorSource != null
        ? ref.watch(albumColorsProvider(colorSource)).valueOrNull
        : null;
    final liveAccent = ref?.watch(effectiveAccentColorProvider);
    final primaryColor =
        albumColors?.accent ?? liveAccent ?? colorScheme.primary;

    // Watch playback state for UI updates
    final playbackState = ref?.watch(playbackStateProvider);
    final currentTrack = ref?.watch(currentTrackProvider);
    final queueSourceId = ref?.watch(queueSourceIdProvider);
    final isPlaying =
        playbackState?.whenOrNull(data: (s) => s.isPlaying) ?? false;
    final hasCurrentTrack = currentTrack != null;

    // Check if this album is currently playing
    final isAlbumPlaying = queueSourceId == album.id;

    // Determine play button icon
    final playIcon = (isAlbumPlaying && isPlaying)
        ? Icons.pause_rounded
        : Icons.play_arrow_rounded;
    final playButtonColor = colorScheme.primary;
    final playIconColor = colorScheme.onPrimary;

    return Stack(
      children: [
        // Background - Softened fading gradient
        _buildBackground(this.context, album.thumbnailUrl, primaryColor),

        Column(
          children: [
            Expanded(
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  // App Bar with Back and Translucent Dynamic Search
                  SliverAppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    pinned: true,
                    flexibleSpace: _isSearching
                        ? ClipRect(
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: (isDark
                                          ? const Color(0xFF141414)
                                          : Colors.white)
                                      .withValues(alpha: 0.85),
                                  border: Border(
                                    bottom: BorderSide(
                                      color: primaryColor.withValues(
                                        alpha: 0.2,
                                      ),
                                      width: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                        : null,
                    leading: IconButton(
                      icon: Icon(
                        Icons.arrow_back,
                        color: isDark ? Colors.white : colorScheme.onSurface,
                      ),
                      onPressed: () {
                        if (_isSearching) {
                          setState(() {
                            _isSearching = false;
                            _searchQuery = '';
                            _searchController.clear();
                          });
                        } else {
                          Navigator.pop(this.context);
                        }
                      },
                    ),
                    title: _isSearching
                        ? TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            autofocus: true,
                            style: TextStyle(
                              color: isDark
                                  ? Colors.white
                                  : colorScheme.onSurface,
                              fontSize: 16,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Search songs in album...',
                              hintStyle: TextStyle(
                                color: (isDark ? Colors.white : Colors.black)
                                    .withValues(alpha: 0.4),
                                fontSize: 16,
                              ),
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 12,
                              ),
                            ),
                            onChanged: (value) {
                              setState(() {
                                _searchQuery = value;
                              });
                            },
                          )
                        : null,
                    actions: [
                      if (!_isSearching)
                        IconButton(
                          icon: Icon(
                            Icons.search,
                            color: isDark
                                ? Colors.white
                                : colorScheme.onSurface,
                          ),
                          onPressed: () {
                            setState(() {
                              _isSearching = true;
                            });
                          },
                        )
                      else if (_searchQuery.isNotEmpty)
                        IconButton(
                          icon: Icon(
                            Icons.close_rounded,
                            color: isDark
                                ? Colors.white70
                                : colorScheme.onSurface,
                          ),
                          onPressed: () {
                            setState(() {
                              _searchQuery = '';
                              _searchController.clear();
                            });
                          },
                        ),
                    ],
                  ),

                  // Header Section (Hidden when searching)
                  if (!_isSearching)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const SizedBox(height: 10),
                            // Centered Album Art
                            Center(
                              child: Container(
                                height: 292,
                                width: 292,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(26),
                                  boxShadow: [
                                    BoxShadow(
                                      color: primaryColor.withValues(
                                        alpha: isDark ? 0.4 : 0.25,
                                      ),
                                      blurRadius: 38,
                                      spreadRadius: 2,
                                      offset: const Offset(0, 14),
                                    ),
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: isDark ? 0.45 : 0.18,
                                      ),
                                      blurRadius: 18,
                                      offset: const Offset(0, 6),
                                    ),
                                  ],
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.08),
                                    width: 1,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(26),
                                  child: highResThumb != null
                                      ? CachedNetworkImage(
                                          imageUrl: highResThumb,
                                          fit: BoxFit.cover,
                                          placeholder: (_, _) => Container(
                                            color: isDark
                                                ? Colors.grey[900]
                                                : Colors.grey[200],
                                          ),
                                          errorWidget: (_, _, _) => Container(
                                            color: isDark
                                                ? Colors.grey[900]
                                                : Colors.grey[200],
                                          ),
                                        )
                                      : Container(
                                          color: isDark
                                              ? Colors.grey[900]
                                              : Colors.grey[200],
                                          child: Icon(
                                            Icons.album,
                                            color: isDark
                                                ? Colors.white
                                                : colorScheme.onSurface,
                                            size: 80,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 28),

                            // Title
                            SizedBox(
                              width: double.infinity,
                              child: Text(
                                album.title,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white
                                      : colorScheme.onSurface,
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.6,
                                  height: 1.15,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),

                            // Artist Subtitle — tappable when an artist id exists
                            Center(
                              child: album.artistId.isNotEmpty
                                  ? InkWell(
                                      onTap: () => _openArtist(album),
                                      borderRadius: BorderRadius.circular(16),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              album.artist,
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: primaryColor,
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(
                                              Icons.open_in_new_rounded,
                                              size: 12,
                                              color: (isDark
                                                      ? Colors.white
                                                      : colorScheme.onSurface)
                                                  .withValues(alpha: 0.4),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  : Text(
                                      album.artist,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: isDark
                                            ? Colors.white.withValues(alpha: 0.9)
                                            : colorScheme.onSurface,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 14),

                            // Glassy outlined metadata pills: Year, Tracks, Total Time
                            Center(
                              child: Wrap(
                                alignment: WrapAlignment.center,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (year != null && year.isNotEmpty)
                                    _buildMetadataPill(
                                      year,
                                      isDark,
                                      icon: Icons.calendar_today_rounded,
                                    ),
                                  if (trackCount > 0)
                                    _buildMetadataPill(
                                      '$trackCount ${trackCount == 1 ? "track" : "tracks"}',
                                      isDark,
                                      icon: Icons.music_note_rounded,
                                    ),
                                  if (totalTimeFormatted.isNotEmpty)
                                    _buildMetadataPill(
                                      totalTimeFormatted,
                                      isDark,
                                      icon: Icons.timer_outlined,
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),

                            // Description/Info
                            if (album.description != null &&
                                album.description!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Text(
                                  album.description!,
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isDark
                                        ? Colors.white54
                                        : colorScheme.onSurface.withValues(
                                            alpha: 0.54,
                                          ),
                                    fontSize: 13.5,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 32),

                            // Action Buttons Row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _buildCircleButton(
                                  Icons.download_rounded,
                                  () {
                                    if (allTracks.isNotEmpty) {
                                      _downloadAlbum(
                                        this.context,
                                        ref,
                                        album,
                                        allTracks,
                                      );
                                    }
                                  },
                                  isDark: isDark,
                                  colorScheme: colorScheme,
                                ),
                                _buildCircleButton(
                                  Icons.shuffle_rounded,
                                  () {
                                    if (playerService != null &&
                                        allTracks.isNotEmpty) {
                                      final shuffled = List<Track>.from(
                                        allTracks,
                                      )..shuffle();
                                      playerService.playQueue(
                                        shuffled,
                                        startIndex: 0,
                                        sourceId: album.id,
                                        sourceTitle: album.title,
                                      );
                                    }
                                  },
                                  isDark: isDark,
                                  colorScheme: colorScheme,
                                ),

                                // Play Button
                                Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: playButtonColor.withValues(
                                          alpha: isDark ? 0.5 : 0.3,
                                        ),
                                        blurRadius: 22,
                                        spreadRadius: 4,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.25),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Container(
                                    height: 72,
                                    width: 72,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          playButtonColor,
                                          Color.lerp(
                                            playButtonColor,
                                            Colors.black,
                                            0.22,
                                          )!,
                                        ],
                                      ),
                                    ),
                                    child: IconButton(
                                      icon: Icon(playIcon, color: playIconColor),
                                      iconSize: 42,
                                      onPressed: () {
                                        if (!isLoading &&
                                            playerService != null &&
                                            allTracks.isNotEmpty) {
                                          if (isAlbumPlaying && isPlaying) {
                                            playerService.pause();
                                          } else {
                                            playerService.playQueue(
                                              allTracks,
                                              startIndex: 0,
                                              sourceId: album.id,
                                              sourceTitle: album.title,
                                            );
                                          }
                                        }
                                      },
                                    ),
                                  ),
                                ),

                                _buildCircleButton(
                                  Icons.more_vert_rounded,
                                  () {
                                    _showAlbumOptions(
                                      this.context,
                                      ref,
                                      album,
                                      allTracks,
                                      playerService,
                                    );
                                  },
                                  isDark: isDark,
                                  colorScheme: colorScheme,
                                ),
                              ],
                            ),
                            const SizedBox(height: 32),
                          ],
                        ),
                      ),
                    ),

                  // Control bar: Sort on LEFT, View Switcher on RIGHT
                  if (!isLoading && allTracks.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _buildControlBar(
                        isDark,
                        primaryColor,
                        this.context.l10n,
                        displayTracks.length,
                      ),
                    ),

                  // Tracks List
                  if (isLoading)
                    SliverSkeletonizer(
                      enabled: true,
                      child: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => ListTile(
                            leading: Skeleton.replace(
                              width: 48,
                              height: 48,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.grey,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                            title: Text(BoneMock.name),
                            subtitle: Text(BoneMock.words(2)),
                            trailing: const Icon(Icons.more_vert),
                          ),
                          childCount: 8,
                        ),
                      ),
                    )
                  else if (displayTracks.isEmpty)
                    SliverFillRemaining(
                      child: Center(
                        child: Text(
                          _searchQuery.isNotEmpty
                              ? 'No songs matching "$_searchQuery"'
                              : this.context.l10n.noTracksFound,
                          style: TextStyle(
                            color: isDark
                                ? Colors.white54
                                : colorScheme.onSurface.withValues(alpha: 0.54),
                          ),
                        ),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final track = displayTracks[index];
                        final isTrackPlaying = currentTrack?.id == track.id;
                        final artworkUrl =
                            track.bestThumbnail ?? album.bestThumbnail;

                        if (_isCompactView) {
                          return ListTile(
                            contentPadding: const EdgeInsets.fromLTRB(
                              16,
                              2,
                              4,
                              2,
                            ),
                            selected: isTrackPlaying,
                            selectedTileColor: (isDark
                                    ? Colors.white
                                    : colorScheme.onSurface)
                                .withValues(alpha: 0.1),
                            leading: SizedBox(
                              width: 28,
                              child: isTrackPlaying
                                  ? Center(
                                      child: _AlbumEqualizer(
                                        color: primaryColor,
                                        size: 1.0,
                                      ),
                                    )
                                  : Text(
                                      '${index + 1}',
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      softWrap: false,
                                      style: TextStyle(
                                        color: isTrackPlaying
                                            ? primaryColor
                                            : (isDark
                                                ? Colors.white54
                                                : colorScheme.onSurface
                                                    .withValues(alpha: 0.54)),
                                        fontSize: 14,
                                        fontWeight: isTrackPlaying
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                            ),
                            title: Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isTrackPlaying
                                    ? primaryColor
                                    : (isDark
                                          ? Colors.white
                                          : colorScheme.onSurface),
                                fontSize: 15,
                                fontWeight: isTrackPlaying
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isTrackPlaying
                                    ? primaryColor.withValues(alpha: 0.7)
                                    : (isDark
                                          ? Colors.white60
                                          : colorScheme.onSurface.withValues(
                                              alpha: 0.6,
                                            )),
                                fontSize: 13,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  track.formattedDuration,
                                  style: TextStyle(
                                    color: isDark
                                        ? Colors.white38
                                        : colorScheme.onSurface.withValues(
                                            alpha: 0.38,
                                          ),
                                    fontSize: 12,
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.more_vert,
                                    color: isDark
                                        ? Colors.white54
                                        : colorScheme.onSurface.withValues(
                                            alpha: 0.54,
                                          ),
                                  ),
                                  onPressed: () =>
                                      TrackOptionsSheet.show(context, track),
                                ),
                              ],
                            ),
                            onTap: () {
                              if (playerService != null) {
                                playerService.playQueue(
                                  displayTracks,
                                  startIndex: index,
                                  sourceId: album.id,
                                  sourceTitle: album.title,
                                );
                              }
                            },
                          );
                        }

                        // Detailed list tile view
                        return ListTile(
                          contentPadding: const EdgeInsets.fromLTRB(
                            16,
                            4,
                            4,
                            4,
                          ),
                          selected: isTrackPlaying,
                          selectedTileColor:
                              (isDark ? Colors.white : colorScheme.onSurface)
                                  .withValues(alpha: 0.1),
                          leading: SizedBox(
                            width: 84,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 30,
                                  child: isTrackPlaying
                                      ? Center(
                                          child: _AlbumEqualizer(
                                            color: primaryColor,
                                          ),
                                        )
                                      : Text(
                                          '${index + 1}',
                                          textAlign: TextAlign.right,
                                          maxLines: 1,
                                          softWrap: false,
                                          style: TextStyle(
                                            color: isDark
                                                ? Colors.white54
                                                : colorScheme.onSurface
                                                    .withValues(alpha: 0.54),
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                ),
                                const SizedBox(width: 9),
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isTrackPlaying
                                          ? primaryColor.withValues(alpha: 0.6)
                                          : Colors.transparent,
                                      width: 1.6,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: artworkUrl != null
                                          ? CachedNetworkImage(
                                              imageUrl: artworkUrl,
                                              fit: BoxFit.cover,
                                              memCacheWidth: 80,
                                              memCacheHeight: 80,
                                              placeholder: (_, _) => Container(
                                                color: isDark
                                                    ? Colors.grey[900]
                                                    : Colors.grey[200],
                                              ),
                                              errorWidget: (_, _, _) =>
                                                  Container(
                                                color: isDark
                                                    ? Colors.grey[900]
                                                    : Colors.grey[200],
                                              ),
                                            )
                                          : Container(
                                              color: isDark
                                                  ? Colors.grey[900]
                                                  : Colors.grey[200],
                                              child: Icon(
                                                Icons.music_note_rounded,
                                                size: 18,
                                                color: isDark
                                                    ? Colors.white54
                                                    : colorScheme.onSurface
                                                        .withValues(
                                                          alpha: 0.6,
                                                        ),
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          title: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isTrackPlaying
                                  ? primaryColor
                                  : (isDark
                                        ? Colors.white
                                        : colorScheme.onSurface),
                              fontSize: 16,
                              fontWeight: isTrackPlaying
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            track.formattedDuration.isNotEmpty
                                ? '${track.artist} • ${track.formattedDuration}'
                                : track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isTrackPlaying
                                  ? primaryColor.withValues(alpha: 0.7)
                                  : (isDark
                                        ? Colors.white60
                                        : colorScheme.onSurface.withValues(
                                            alpha: 0.6,
                                          )),
                              fontSize: 14,
                            ),
                          ),
                          trailing: IconButton(
                            icon: Icon(
                              Icons.more_vert,
                              color: isDark
                                  ? Colors.white54
                                  : colorScheme.onSurface.withValues(
                                      alpha: 0.54,
                                    ),
                            ),
                            onPressed: () =>
                                TrackOptionsSheet.show(context, track),
                          ),
                          onTap: () {
                            if (playerService != null) {
                              playerService.playQueue(
                                displayTracks,
                                startIndex: index,
                                sourceId: album.id,
                                sourceTitle: album.title,
                              );
                            }
                          },
                        );
                      }, childCount: displayTracks.length),
                    ),

                  // Footer credits
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(32, 4, 32, 28),
                      child: Column(
                        children: [
                          Container(
                            height: 1,
                            color: (isDark ? Colors.white : Colors.black)
                                .withValues(alpha: 0.07),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            [
                              if (year != null && year.isNotEmpty) year,
                              if (trackCount > 0)
                                trackCount == 1
                                    ? '1 track'
                                    : '$trackCount tracks',
                              if (totalTimeFormatted.isNotEmpty)
                                totalTimeFormatted,
                              if (album.artist.isNotEmpty) album.artist,
                            ].join('  •  '),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.3,
                              color: (isDark ? Colors.white : Colors.black)
                                  .withValues(alpha: 0.3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Bottom Padding for Mini Player
                  const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
                ],
              ),
            ),

            if (hasCurrentTrack)
              MusicMiniPlayer(onTap: () => NowPlayingScreen.show(this.context)),
          ],
        ),
      ],
    );
  }

  Widget _buildCircleButton(
    IconData icon,
    VoidCallback onTap, {
    required bool isDark,
    required ColorScheme colorScheme,
    Color? tint,
  }) {
    final fg = tint ?? (isDark ? Colors.white : colorScheme.onSurface);
    return BouncyTouch(
      style: BouncyStyle.button,
      customScale: 0.88,
      onTap: onTap,
      child: Container(
        height: 48,
        width: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.07),
          border: Border.all(
            color: fg.withValues(alpha: 0.18),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(icon, color: fg, size: 22),
      ),
    );
  }

  /// Open the artist page for this album
  void _openArtist(Album album) {
    if (album.artistId.isEmpty) return;
    ArtistPageScreen.open(
      context,
      artistId: album.artistId,
      name: album.artist,
      thumbnailUrl: album.bestThumbnail,
    );
  }

  /// Download all tracks in the album
  void _downloadAlbum(
    BuildContext context,
    WidgetRef? ref,
    Album album,
    List<Track> tracks,
  ) {
    if (ref == null || tracks.isEmpty) return;

    // Use the download manager notifier to queue all tracks
    final downloadManager = ref.read(downloadManagerProvider.notifier);
    downloadManager.addMultipleToQueue(tracks);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.l10n.downloadingTracksFromAlbum(tracks.length, album.title),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildSheetActionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    return BouncyTouch(
      style: BouncyStyle.card,
      customScale: 0.98,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Icon(icon, color: iconColor, size: 18),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: textColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: textColor.withValues(alpha: 0.25),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  /// Show album options bottom sheet
  void _showAlbumOptions(
    BuildContext context,
    WidgetRef? ref,
    Album album,
    List<Track> tracks,
    dynamic playerService,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = context.l10n;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Consumer(
          builder: (context, refConsumer, child) {
            final liveAccent = refConsumer.watch(effectiveAccentColorProvider);
            final sheetBg = isDark
                ? const Color(0xFF141414).withValues(alpha: 0.92)
                : Colors.white.withValues(alpha: 0.95);
            final textColor = isDark ? Colors.white : Colors.black87;
            final secondaryColor = textColor.withValues(alpha: 0.55);

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Container(
                      decoration: BoxDecoration(
                        color: sheetBg,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: liveAccent.withValues(alpha: 0.22),
                          width: 1.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 32,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Drag handle
                              Center(
                                child: Container(
                                  width: 36,
                                  height: 4,
                                  margin: const EdgeInsets.only(bottom: 12),
                                  decoration: BoxDecoration(
                                    color: textColor.withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),

                              // Album Header Card
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: textColor.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: liveAccent.withValues(alpha: 0.15),
                                    width: 0.8,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: SizedBox(
                                        width: 50,
                                        height: 50,
                                        child: album.thumbnailUrl != null
                                            ? CachedNetworkImage(
                                                imageUrl: album.thumbnailUrl!,
                                                fit: BoxFit.cover,
                                              )
                                            : Container(
                                                color: isDark
                                                    ? Colors.grey[800]
                                                    : Colors.grey[300],
                                                child: const Icon(
                                                  Icons.album_rounded,
                                                ),
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            album.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                              color: textColor,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            album.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              color: secondaryColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 14),

                              // Section: ALBUM ACTIONS
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 6, bottom: 4),
                                child: Text(
                                  'ALBUM ACTIONS',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1.2,
                                    color: secondaryColor,
                                  ),
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  color: textColor.withValues(alpha: 0.04),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                  horizontal: 4,
                                ),
                                child: Column(
                                  children: [
                                    _buildSheetActionTile(
                                      icon: Icons.play_arrow_rounded,
                                      iconColor: liveAccent,
                                      title: l10n.play,
                                      textColor: textColor,
                                      onTap: () {
                                        Navigator.pop(ctx);
                                        if (playerService != null &&
                                            tracks.isNotEmpty) {
                                          playerService.playQueue(
                                            tracks,
                                            startIndex: 0,
                                            sourceId: album.id,
                                            sourceTitle: album.title,
                                          );
                                        }
                                      },
                                    ),
                                    _buildSheetActionTile(
                                      icon: Icons.shuffle_rounded,
                                      iconColor: liveAccent,
                                      title: l10n.shuffle,
                                      textColor: textColor,
                                      onTap: () {
                                        Navigator.pop(ctx);
                                        if (playerService != null &&
                                            tracks.isNotEmpty) {
                                          final shuffled =
                                              List<Track>.from(tracks)
                                                ..shuffle();
                                          playerService.playQueue(
                                            shuffled,
                                            startIndex: 0,
                                            sourceId: album.id,
                                            sourceTitle: album.title,
                                          );
                                        }
                                      },
                                    ),
                                    _buildSheetActionTile(
                                      icon: Iconsax.add_square,
                                      iconColor: liveAccent,
                                      title: l10n.addToQueue,
                                      textColor: textColor,
                                      onTap: () {
                                        Navigator.pop(ctx);
                                        if (playerService != null &&
                                            tracks.isNotEmpty) {
                                          for (final track in tracks) {
                                            playerService.addToQueue(track);
                                          }
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                l10n.addedTracksToQueueCount(
                                                  tracks.length,
                                                ),
                                              ),
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                    _buildSheetActionTile(
                                      icon: Icons.download_rounded,
                                      iconColor: liveAccent,
                                      title: l10n.downloadAlbum,
                                      textColor: textColor,
                                      onTap: () {
                                        Navigator.pop(ctx);
                                        _downloadAlbum(
                                          context,
                                          ref,
                                          album,
                                          tracks,
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Small animated 3-bar equalizer shown on the currently playing track
class _AlbumEqualizer extends StatefulWidget {
  final Color color;
  final double size;

  const _AlbumEqualizer({required this.color, this.size = 1.0});

  @override
  State<_AlbumEqualizer> createState() => _AlbumEqualizerState();
}

class _AlbumEqualizerState extends State<_AlbumEqualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return AnimatedBuilder(
      animation: _animController,
      builder: (context, child) {
        final val = _animController.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _bar((6 + val * 7) * s),
            const SizedBox(width: 2),
            _bar((13 - val * 7) * s),
            const SizedBox(width: 2),
            _bar((5 + val * 8) * s),
          ],
        );
      },
    );
  }

  Widget _bar(double height) {
    return Container(
      width: 3.5 * widget.size,
      height: height.clamp(2.0, 20.0),
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
