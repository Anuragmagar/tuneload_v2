import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:marquee/marquee.dart';
import '../../core/design_system/design_system.dart';
import '../../core/services/cache/hive_service.dart';
import '../../core/l10n/app_localizations_x.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../services/download_service.dart';
import 'album_screen.dart' hide albumColorsProvider;
import 'artist_screen.dart';
import 'playlist_picker_sheet.dart';

/// Track options bottom sheet
/// Displays categorized, uniform options in glass section cards
class TrackOptionsSheet extends ConsumerWidget {
  final Track track;
  final String? sourcePlaylistId;
  final bool isLocalPlaylist;
  final bool hideExploreShare;

  const TrackOptionsSheet({
    super.key,
    required this.track,
    this.sourcePlaylistId,
    this.isLocalPlaylist = false,
    this.hideExploreShare = false,
  });

  static void show(
    BuildContext context,
    Track track, {
    String? sourcePlaylistId,
    bool isLocalPlaylist = false,
    bool hideExploreShare = false,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => TrackOptionsSheet(
        track: track,
        sourcePlaylistId: sourcePlaylistId,
        isLocalPlaylist: isLocalPlaylist,
        hideExploreShare: hideExploreShare,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveAccent = ref.watch(effectiveAccentColorProvider);
    // Artwork colors are reserved for Now Playing / mini player only.
    final accentColor = effectiveAccent;

    final sheetBg = isDark
        ? const Color(0xFF141414).withValues(alpha: 0.90)
        : Colors.white.withValues(alpha: 0.94);
    final textColor = isDark ? Colors.white : Colors.black87;
    final secondaryColor = textColor.withValues(alpha: 0.55);

    final isLiked = ref.watch(isTrackLikedProvider(track.id));
    final playerService = ref.watch(audioPlayerServiceProvider);

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
                  color: accentColor.withValues(alpha: 0.22),
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
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Handle
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

                      // Track Info Header Card
                      _buildHeaderCard(accentColor, textColor, secondaryColor),

                      const SizedBox(height: 16),

                      // SECTION 1: PLAYBACK & QUEUE
                      _buildSectionTitle('PLAYBACK & QUEUE', secondaryColor),
                      const SizedBox(height: 6),
                      _buildSectionCard(
                        textColor: textColor,
                        children: [
                          // Play Next
                          _buildOptionTile(
                            icon: Iconsax.music_playlist,
                            iconColor: accentColor,
                            title: l10n.playNext,
                            textColor: textColor,
                            onTap: () {
                              playerService.playNext(track);
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.playingTrackNext(track.title)),
                                ),
                              );
                            },
                          ),

                          // Add to Queue
                          _buildOptionTile(
                            icon: Iconsax.add_square,
                            iconColor: accentColor,
                            title: l10n.addToQueue,
                            textColor: textColor,
                            onTap: () {
                              playerService.addToQueue([track]);
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.addedTrackToQueue(track.title)),
                                ),
                              );
                            },
                          ),

                          // Start Radio
                          _buildOptionTile(
                            icon: Iconsax.radio,
                            iconColor: accentColor,
                            title: l10n.startRadio,
                            textColor: textColor,
                            onTap: () {
                              playerService.playTrack(track, enableRadio: true);
                              Navigator.pop(context);
                            },
                          ),

                          // Play Next in Jam (Conditional)
                          Consumer(
                            builder: (context, ref, child) {
                              final isInJam = ref.watch(isInJamSessionProvider);
                              final canControlPlayback = ref.watch(
                                canControlJamPlaybackProvider,
                              );
                              if (!isInJam || !canControlPlayback) {
                                return const SizedBox.shrink();
                              }
                              return _buildOptionTile(
                                icon: Iconsax.music_playlist,
                                iconColor: Colors.purpleAccent,
                                title: l10n.playNextInJam,
                                textColor: textColor,
                                onTap: () async {
                                  final jamsService = ref.read(jamsServiceProvider);
                                  if (jamsService != null) {
                                    await jamsService.playNextInQueue(
                                      videoId: track.id,
                                      title: track.title,
                                      artist: track.artist,
                                      thumbnailUrl: track.thumbnailUrl,
                                      durationMs: track.duration.inMilliseconds,
                                    );
                                  }
                                  if (context.mounted) {
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(l10n.playTrackNextInJam(track.title)),
                                      ),
                                    );
                                  }
                                },
                              );
                            },
                          ),

                          // Add to Jam Queue (Conditional)
                          Consumer(
                            builder: (context, ref, child) {
                              final isInJam = ref.watch(isInJamSessionProvider);
                              final canControlPlayback = ref.watch(
                                canControlJamPlaybackProvider,
                              );
                              if (!isInJam || !canControlPlayback) {
                                return const SizedBox.shrink();
                              }
                              return _buildOptionTile(
                                icon: Iconsax.profile_2user,
                                iconColor: Colors.purpleAccent,
                                title: l10n.addToJamQueue,
                                textColor: textColor,
                                onTap: () async {
                                  final jamsService = ref.read(jamsServiceProvider);
                                  if (jamsService != null) {
                                    await jamsService.addToQueue(
                                      videoId: track.id,
                                      title: track.title,
                                      artist: track.artist,
                                      thumbnailUrl: track.thumbnailUrl,
                                      durationMs: track.duration.inMilliseconds,
                                    );
                                  }
                                  if (context.mounted) {
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          l10n.addedTrackToJamQueue(track.title),
                                        ),
                                      ),
                                    );
                                  }
                                },
                              );
                            },
                          ),
                        ],
                      ),

                      const SizedBox(height: 14),

                      // SECTION 2: LIBRARY & PLAYLISTS
                      _buildSectionTitle('LIBRARY & PLAYLISTS', secondaryColor),
                      const SizedBox(height: 6),
                      _buildSectionCard(
                        textColor: textColor,
                        children: [
                          // Like / Unlike
                          _buildOptionTile(
                            icon: isLiked ? Iconsax.heart5 : Iconsax.heart,
                            iconColor: isLiked ? Colors.redAccent : accentColor,
                            title: isLiked
                                ? l10n.removeFromLikedSongs
                                : l10n.addToLikedSongs,
                            textColor: textColor,
                            onTap: () {
                              _toggleLike(ref, isLiked);
                              Navigator.pop(context);
                            },
                          ),

                          // Add to Playlist
                          _buildOptionTile(
                            icon: Iconsax.music_square_add,
                            iconColor: accentColor,
                            title: l10n.addToPlaylist,
                            textColor: textColor,
                            onTap: () {
                              Navigator.pop(context);
                              PlaylistPickerSheet.show(context, track);
                            },
                          ),

                          // Download / Remove Download
                          Consumer(
                            builder: (context, ref, child) {
                              final isDownloaded = ref.watch(
                                isTrackDownloadedProvider(track.id),
                              );
                              final progress = ref.watch(
                                trackDownloadProgressProvider(track.id),
                              );
                              final phase = ref.watch(
                                trackDownloadPhaseProvider(track.id),
                              );
                              final isConverting =
                                  phase == DownloadPhase.converting;

                              if (isDownloaded) {
                                return _buildOptionTile(
                                  icon: Iconsax.trash,
                                  iconColor: Colors.redAccent,
                                  title: l10n.removeDownload,
                                  textColor: textColor,
                                  onTap: () async {
                                    Navigator.pop(context);
                                    await ref
                                        .read(downloadManagerProvider.notifier)
                                        .removeDownload(track.id);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(l10n.removeDownload),
                                        ),
                                      );
                                    }
                                  },
                                );
                              }

                              return _buildOptionTile(
                                  icon: Iconsax.document_download,
                                  iconColor: accentColor,
                                  title: isConverting
                                      ? l10n.converting
                                      : progress != null
                                          ? l10n.downloadingProgress(
                                              (progress * 100).toInt(),
                                            )
                                          : l10n.download,
                                  textColor: textColor,
                                  onTap: (isConverting || progress != null)
                                      ? () => Navigator.pop(context)
                                    : () {
                                        ref
                                            .read(downloadManagerProvider.notifier)
                                            .addToQueue(track);
                                        Navigator.pop(context);
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              l10n.downloadStartingTrack(track.title),
                                            ),
                                          ),
                                        );
                                      },
                              );
                            },
                          ),

                          // Remove from Playlist (if applicable)
                          if (sourcePlaylistId != null &&
                              (isLocalPlaylist || track.setVideoId != null))
                            _buildOptionTile(
                              icon: Iconsax.trash,
                              iconColor: Colors.redAccent,
                              title: l10n.removeFromPlaylist,
                              textColor: textColor,
                              onTap: () async {
                                if (isLocalPlaylist) {
                                  ref
                                      .read(localPlaylistsProvider.notifier)
                                      .removeTrackFromPlaylist(sourcePlaylistId!, track.id);
                                  Navigator.pop(context);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(l10n.removedFromPlaylist)),
                                  );
                                } else if (track.setVideoId != null) {
                                  final container = ProviderScope.containerOf(context, listen: false);
                                  final scaffoldMessenger = ScaffoldMessenger.of(context);
                                  final localL10n = l10n;
                                  final ytAction = container.read(ytMusicPlaylistActionProvider);
                                  final notifier = container.read(ytMusicPlaylistProvider(sourcePlaylistId!).notifier);

                                  Navigator.pop(context);
                                  final success = await ytAction.removeSong(sourcePlaylistId!, track.id, track.setVideoId!);

                                  if (success) {
                                    await notifier.removeTrackOptimistically(track.id);
                                    container.invalidate(ytMusicPlaylistProvider(sourcePlaylistId!));
                                    scaffoldMessenger.showSnackBar(
                                      SnackBar(content: Text(localL10n.removedFromPlaylist)),
                                    );
                                  } else {
                                    scaffoldMessenger.showSnackBar(
                                      SnackBar(content: Text(localL10n.unknownError)),
                                    );
                                  }
                                }
                              },
                            ),
                        ],
                      ),

                      const SizedBox(height: 14),

                      // SECTION 3: EXPLORE
                      if (!hideExploreShare) ...[
                        _buildSectionTitle('EXPLORE', secondaryColor),
                        const SizedBox(height: 6),
                        _buildSectionCard(
                          textColor: textColor,
                          children: [
                          // Go to Artist
                          if (track.artistId.isNotEmpty)
                            _buildOptionTile(
                              icon: Iconsax.profile_2user,
                              iconColor: accentColor,
                              title: l10n.goToArtist,
                              textColor: textColor,
                              onTap: () {
                                Navigator.pop(context);
                                ArtistScreen.open(
                                  context,
                                  artistId: track.artistId,
                                  name: track.artist,
                                );
                              },
                            ),

                          // Go to Album
                          if (track.albumId != null)
                            _buildOptionTile(
                              icon: Iconsax.music_dashboard,
                              iconColor: accentColor,
                              title: l10n.goToAlbum,
                              textColor: textColor,
                              onTap: () {
                                Navigator.pop(context);
                                AlbumScreen.open(
                                  context,
                                  albumId: track.albumId!,
                                  title: track.album,
                                  thumbnailUrl: track.thumbnailUrl,
                                );
                              },
                            ),
                        ],
                      ),
                      ],

                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderCard(Color accentColor, Color textColor, Color secondaryColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.15),
          width: 1.0,
        ),
      ),
      child: Row(
        children: [
          // Album Artwork with glow
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: accentColor.withValues(alpha: 0.30),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 52,
                height: 52,
                child: track.thumbnailUrl != null
                    ? CachedNetworkImage(
                        imageUrl: track.thumbnailUrl!,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        color: accentColor.withValues(alpha: 0.2),
                        child: Icon(
                          Iconsax.music,
                          color: accentColor,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title with Marquee on overflow
                LayoutBuilder(
                  builder: (context, constraints) {
                    final titleStyle = TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: textColor,
                    );
                    final textPainter = TextPainter(
                      text: TextSpan(text: track.title, style: titleStyle),
                      maxLines: 1,
                      textDirection: TextDirection.ltr,
                    )..layout();

                    if (textPainter.width > constraints.maxWidth) {
                      return SizedBox(
                        height: 22,
                        child: Marquee(
                          text: track.title,
                          style: titleStyle,
                          scrollAxis: Axis.horizontal,
                          blankSpace: 36.0,
                          velocity: 28.0,
                          pauseAfterRound: const Duration(seconds: 2),
                          startPadding: 0.0,
                          accelerationDuration: const Duration(seconds: 1),
                          accelerationCurve: Curves.linear,
                          decelerationDuration:
                              const Duration(milliseconds: 500),
                        ),
                      );
                    }
                    return Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    );
                  },
                ),
                const SizedBox(height: 2),
                // Artist with Marquee on overflow
                LayoutBuilder(
                  builder: (context, constraints) {
                    final artistStyle = TextStyle(
                      fontSize: 13,
                      color: secondaryColor,
                    );
                    final textPainter = TextPainter(
                      text: TextSpan(text: track.artist, style: artistStyle),
                      maxLines: 1,
                      textDirection: TextDirection.ltr,
                    )..layout();

                    if (textPainter.width > constraints.maxWidth) {
                      return SizedBox(
                        height: 18,
                        child: Marquee(
                          text: track.artist,
                          style: artistStyle,
                          scrollAxis: Axis.horizontal,
                          blankSpace: 36.0,
                          velocity: 28.0,
                          pauseAfterRound: const Duration(seconds: 2),
                          startPadding: 0.0,
                          accelerationDuration: const Duration(seconds: 1),
                          accelerationCurve: Curves.linear,
                          decelerationDuration:
                              const Duration(milliseconds: 500),
                        ),
                      );
                    }
                    return Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: artistStyle,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, Color secondaryColor) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 2),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: secondaryColor,
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required Color textColor,
    required List<Widget> children,
  }) {
    // Filter out SizedBox.shrink() items
    final validChildren = children.where((w) => w is! SizedBox).toList();

    return Container(
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: validChildren,
      ),
    );
  }

  Widget _buildOptionTile({
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

  void _toggleLike(WidgetRef ref, bool isLiked) async {
    if (isLiked) {
      ref.read(likedSongsProvider.notifier).unlike(track.id);
      ref
          .read(explicitlyUnlikedIdsProvider.notifier)
          .update((state) => {...state, track.id});
    } else {
      ref.read(likedSongsProvider.notifier).like(track);
      ref
          .read(explicitlyUnlikedIdsProvider.notifier)
          .update(
            (state) => state.where((id) => id != track.id).toSet(),
          );
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
}
