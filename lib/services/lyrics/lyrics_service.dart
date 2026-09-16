import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tuneload/core/services/cache/hive_service.dart';
import 'package:tuneload/core/utils/activity_log.dart';
import 'package:tuneload/data/entities/lyrics_entity.dart';
import 'package:tuneload/data/repositories/music_repository.dart'
    show CacheAnalytics;
import 'lyrics_models.dart';
import 'betterlyrics_provider.dart';
import 'lrclib_provider.dart';
import 'genius_provider.dart';
import 'youtube_lyrics_provider.dart';

/// Provider names enum for type safety
enum ProviderName { betterLyrics, lrclib, youtubeMusic, genius }

/// All available provider names in order
const providerNames = [
  ProviderName.betterLyrics,
  ProviderName.lrclib,
  ProviderName.youtubeMusic,
  ProviderName.genius,
];

/// Extension to get display name
extension ProviderNameExt on ProviderName {
  String get displayName {
    switch (this) {
      case ProviderName.betterLyrics:
        return 'BetterLyrics';
      case ProviderName.lrclib:
        return 'LRCLib';
      case ProviderName.youtubeMusic:
        return 'YouTube Music';
      case ProviderName.genius:
        return 'Genius';
    }
  }
}

/// Lightweight background lyrics warmup for playback.
/// Prioritizes LRCLib for fastest synced lyric availability.
class LyricsWarmupService {
  static final LyricsWarmupService instance = LyricsWarmupService._();
  LyricsWarmupService._();

  final BetterLyricsProvider _betterLyrics = BetterLyricsProvider();
  final LRCLibProvider _lrclib = LRCLibProvider();
  final GeniusProvider _genius = GeniusProvider();
  final Set<String> _inFlight = <String>{};

  Future<void> prefetchForTrack({
    required String videoId,
    required String title,
    required String artist,
    String? album,
    required int durationSeconds,
  }) async {
    if (videoId.isEmpty) return;
    if (_inFlight.contains(videoId)) return;
    if (_hasCachedLyrics(videoId)) return;

    _inFlight.add(videoId);
    try {
      final info = LyricsSearchInfo(
        videoId: videoId,
        title: title,
        artist: artist,
        album: album,
        durationSeconds: durationSeconds,
      );

      LyricResult? result = await _betterLyrics.search(info);
      if (result == null || !result.hasLyrics) {
        result = await _lrclib.search(info);
      }
      if (result == null || !result.hasLyrics) {
        result = await _genius.search(info);
      }
      if (result == null || !result.hasLyrics) return;

      _cacheLyrics(videoId, title, artist, result);
      ActivityLogService.success(
        'lyrics',
        'Lyrics warmed for "$title" via ${result.source}',
      );
      if (kDebugMode) {
        print(
          'LyricsService: Warmed lyrics for $videoId using ${result.source}',
        );
      }
    } catch (e) {
      ActivityLogService.w('lyrics', 'Lyrics warmup failed for "$title": $e');
      if (kDebugMode) {
        print('LyricsService: Warmup failed for $videoId: $e');
      }
    } finally {
      _inFlight.remove(videoId);
    }
  }

  bool _hasCachedLyrics(String videoId) {
    try {
      final cached = HiveService.lyricsBox.get(videoId);
      return cached != null && !cached.isExpired && cached.hasLyrics;
    } catch (_) {
      return false;
    }
  }

  void _cacheLyrics(
    String videoId,
    String title,
    String artist,
    LyricResult result,
  ) {
    final entity = LyricsEntity(
      trackId: videoId,
      title: title,
      artist: artist,
      syncedLyrics: _linesToLrc(result.lines),
      plainLyrics: result.lyrics,
      provider: result.source,
      cachedAt: DateTime.now(),
      ttlDays: 7,
      wordSyncData: _serializeWordData(result.lines),
    );
    HiveService.lyricsBox.put(videoId, entity);
  }

  /// Serialize word-level timing to JSON for cache storage
  static String? _serializeWordData(List<LyricLine>? lines) {
    if (lines == null || lines.isEmpty) return null;
    final hasAnyWords = lines.any((l) => l.hasWordSync);
    if (!hasAnyWords) return null;
    return jsonEncode(
      lines.map((l) => l.words?.map((w) => w.toJson()).toList()).toList(),
    );
  }

  String? _linesToLrc(List<LyricLine>? lines) {
    if (lines == null || lines.isEmpty) return null;
    final buffer = StringBuffer();
    for (final line in lines) {
      final minutes = (line.timeInMs ~/ 60000).toString().padLeft(2, '0');
      final seconds = ((line.timeInMs % 60000) ~/ 1000).toString().padLeft(
        2,
        '0',
      );
      final millis = ((line.timeInMs % 1000) ~/ 10).toString().padLeft(2, '0');
      buffer.writeln('[$minutes:$seconds.$millis]${line.text}');
    }
    return buffer.toString();
  }
}

/// Lyrics state for a track
class LyricsState {
  final String? videoId;
  final Map<ProviderName, ProviderStatus> providers;
  final ProviderName currentProvider;
  final bool hasManuallySwitched;

  const LyricsState({
    this.videoId,
    this.providers = const {},
    this.currentProvider = ProviderName.lrclib,
    this.hasManuallySwitched = false,
  });

  ProviderStatus get currentStatus =>
      providers[currentProvider] ?? const ProviderStatus();

  LyricResult? get currentLyrics => currentStatus.data;

  bool get isLoading => currentStatus.state == LyricsProviderState.fetching;

  bool get hasLyrics => currentLyrics?.hasLyrics ?? false;

  LyricsState copyWith({
    String? videoId,
    Map<ProviderName, ProviderStatus>? providers,
    ProviderName? currentProvider,
    bool? hasManuallySwitched,
  }) => LyricsState(
    videoId: videoId ?? this.videoId,
    providers: providers ?? this.providers,
    currentProvider: currentProvider ?? this.currentProvider,
    hasManuallySwitched: hasManuallySwitched ?? this.hasManuallySwitched,
  );
}

/// Lyrics service notifier with caching
class LyricsNotifier extends StateNotifier<LyricsState> {
  final Map<ProviderName, LyricsProvider> _providers;
  LyricsSearchInfo? _lastSearchInfo;

  LyricsNotifier()
    : _providers = {
        ProviderName.betterLyrics: BetterLyricsProvider(),
        ProviderName.lrclib: LRCLibProvider(),
        ProviderName.youtubeMusic: YouTubeLyricsProvider(),
        ProviderName.genius: GeniusProvider(),
      },
      super(const LyricsState());

  /// Fetch lyrics for a track from all providers (with caching)
  Future<void> fetchLyrics(LyricsSearchInfo info) async {
    _lastSearchInfo = info;

    // Ignore duplicate fetches for the same track while it's already loading.
    if (state.videoId == info.videoId) {
      final isAlreadyFetching = state.providers.values.any(
        (s) => s.state == LyricsProviderState.fetching,
      );
      if (isAlreadyFetching) return;
    }

    // Check cache first
    final cached = _getCachedLyrics(info.videoId);
    if (cached != null) {
      CacheAnalytics.instance.recordCacheHit();
      ActivityLogService.i('lyrics', 'Lyrics from cache for "${info.title}"');
      if (kDebugMode) {
        print('LyricsService: Using cached lyrics for ${info.videoId}');
      }
      final cachedProvider =
          _providerNameFromSource(cached.source) ?? ProviderName.betterLyrics;
      final providers = {
        for (final p in providerNames) p: const ProviderStatus(),
      };
      providers[cachedProvider] = ProviderStatus(
        state: LyricsProviderState.done,
        data: cached,
      );
      if (mounted) {
        state = LyricsState(
          videoId: info.videoId,
          providers: providers,
          currentProvider: cachedProvider,
          hasManuallySwitched: false,
        );
      }
      return;
    }

    CacheAnalytics.instance.recordCacheMiss();
    CacheAnalytics.instance.recordNetworkCall();
    ActivityLogService.i('lyrics', 'Fetching lyrics for "${info.title}"...');
    // Reset state for new track
    if (mounted) {
      state = LyricsState(
        videoId: info.videoId,
        providers: {
          for (final p in providerNames)
            p: const ProviderStatus(state: LyricsProviderState.idle),
        },
        currentProvider: state.currentProvider,
        hasManuallySwitched: false,
      );
    }

    // BetterLyrics is the primary source (best quality word-level sync).
    await _fetchFromProvider(ProviderName.betterLyrics, info);
    final betterStatus = state.providers[ProviderName.betterLyrics];
    if ((betterStatus?.data?.hasLyrics ?? false) &&
        betterStatus?.state == LyricsProviderState.done) {
      if (!state.hasManuallySwitched) {
        state = state.copyWith(currentProvider: ProviderName.betterLyrics);
      }
      _cacheBestResult(info);
      return;
    }

    // LRCLib fallback (synced, community-driven).
    await _fetchFromProvider(ProviderName.lrclib, info);
    final lrcLibStatus = state.providers[ProviderName.lrclib];
    if ((lrcLibStatus?.data?.hasLyrics ?? false) &&
        lrcLibStatus?.state == LyricsProviderState.done) {
      if (!state.hasManuallySwitched) {
        state = state.copyWith(currentProvider: ProviderName.lrclib);
      }
      _cacheBestResult(info);
      return;
    }

    // YouTube Music & Subtitles fallback (official lyrics / timed captions).
    await _fetchFromProvider(ProviderName.youtubeMusic, info);
    final ytStatus = state.providers[ProviderName.youtubeMusic];
    if ((ytStatus?.data?.hasLyrics ?? false) &&
        ytStatus?.state == LyricsProviderState.done) {
      if (!state.hasManuallySwitched) {
        state = state.copyWith(currentProvider: ProviderName.youtubeMusic);
      }
      _cacheBestResult(info);
      return;
    }

    // Genius fallback (plain text).
    await _fetchFromProvider(ProviderName.genius, info);

    // Auto-select best provider if not manually switched
    if (!state.hasManuallySwitched) {
      _selectBestProvider();
    }

    // Cache the best result
    _cacheBestResult(info);
  }

  /// Get cached lyrics for a track
  LyricResult? _getCachedLyrics(String videoId) {
    try {
      final cached = HiveService.lyricsBox.get(videoId);
      if (cached != null && !cached.isExpired && cached.hasLyrics) {
        // Parse synced lyrics from LRC format back to LyricLine list
        List<LyricLine>? lines;
        if (cached.hasSyncedLyrics) {
          lines = _parseLrcToLines(cached.syncedLyrics!);
          // Restore word-level timing if available
          if (cached.hasWordSync && lines.isNotEmpty) {
            lines = _restoreWordData(lines, cached.wordSyncData!);
          }
        }
        return LyricResult(
          title: cached.title,
          artists: [cached.artist],
          lines: lines,
          lyrics: cached.plainLyrics,
          source: cached.provider,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('LyricsService: Cache read error: $e');
      }
    }
    return null;
  }

  ProviderName? _providerNameFromSource(String? source) {
    if (source == null) return null;
    final normalized = source.trim().toLowerCase();
    if (normalized == 'betterlyrics') return ProviderName.betterLyrics;
    if (normalized == 'lrclib') return ProviderName.lrclib;
    if (normalized.contains('youtube')) return ProviderName.youtubeMusic;
    if (normalized == 'genius') return ProviderName.genius;
    return null;
  }

  /// Parse LRC format string to list of LyricLines
  List<LyricLine> _parseLrcToLines(String lrc) {
    final lines = <LyricLine>[];
    final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
    for (final line in lrc.split('\n')) {
      final match = regex.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final millis = int.parse(match.group(3)!.padRight(3, '0'));
        final text = match.group(4) ?? '';
        final timeInMs = minutes * 60000 + seconds * 1000 + millis;
        lines.add(LyricLine(timeInMs: timeInMs, text: text));
      }
    }
    return lines;
  }

  /// Convert LyricLines to LRC format string for caching
  String? _linesToLrc(List<LyricLine>? lines) {
    if (lines == null || lines.isEmpty) return null;
    final buffer = StringBuffer();
    for (final line in lines) {
      final minutes = (line.timeInMs ~/ 60000).toString().padLeft(2, '0');
      final seconds = ((line.timeInMs % 60000) ~/ 1000).toString().padLeft(
        2,
        '0',
      );
      final millis = ((line.timeInMs % 1000) ~/ 10).toString().padLeft(2, '0');
      buffer.writeln('[$minutes:$seconds.$millis]${line.text}');
    }
    return buffer.toString();
  }

  /// Cache the best lyrics result
  void _cacheBestResult(LyricsSearchInfo info) {
    try {
      final bestStatus = state.currentStatus;
      if (bestStatus.state == LyricsProviderState.done &&
          bestStatus.data != null &&
          bestStatus.data!.hasLyrics) {
        final data = bestStatus.data!;
        final entity = LyricsEntity(
          trackId: info.videoId,
          title: info.title,
          artist: info.artist,
          syncedLyrics: _linesToLrc(data.lines),
          plainLyrics: data.lyrics,
          provider: data.source,
          cachedAt: DateTime.now(),
          ttlDays: 7,
          wordSyncData: _serializeWordData(data.lines),
        );
        HiveService.lyricsBox.put(info.videoId, entity);
        if (kDebugMode) {
          print('LyricsService: Cached lyrics for ${info.videoId}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('LyricsService: Cache write error: $e');
      }
    }
  }

  /// Serialize word-level timing to JSON for cache storage
  static String? _serializeWordData(List<LyricLine>? lines) {
    if (lines == null || lines.isEmpty) return null;
    final hasAnyWords = lines.any((l) => l.hasWordSync);
    if (!hasAnyWords) return null;
    return jsonEncode(
      lines.map((l) => l.words?.map((w) => w.toJson()).toList()).toList(),
    );
  }

  /// Restore word-level timing from cached JSON into parsed LyricLines
  static List<LyricLine> _restoreWordData(
    List<LyricLine> lines,
    String wordSyncJson,
  ) {
    try {
      final wordData = jsonDecode(wordSyncJson) as List;
      if (wordData.length != lines.length) return lines;

      return List.generate(lines.length, (i) {
        final lineWords = wordData[i] as List?;
        if (lineWords == null || lineWords.isEmpty) return lines[i];

        return LyricLine(
          timeInMs: lines[i].timeInMs,
          durationMs: lines[i].durationMs,
          text: lines[i].text,
          words: lineWords
              .map((w) => LyricWord.fromJson(w as Map<String, dynamic>))
              .toList(),
        );
      });
    } catch (e) {
      if (kDebugMode) {
        print('LyricsService: Failed to restore word data: $e');
      }
      return lines;
    }
  }

  Future<void> _fetchFromProvider(
    ProviderName name,
    LyricsSearchInfo info,
  ) async {
    if (!mounted) return;
    final currentProviders = Map<ProviderName, ProviderStatus>.from(
      state.providers,
    );
    currentProviders[name] = const ProviderStatus(
      state: LyricsProviderState.fetching,
    );
    state = state.copyWith(providers: currentProviders);

    try {
      final provider = _providers[name]!;
      final result = await provider.search(info);

      if (!mounted) return;
      ActivityLogService.i(
        'lyrics',
        '${name.name} → ${result != null && result.hasLyrics ? 'found' : 'no lyrics'} for "${info.title}"',
      );
      _updateProviderStatus(
        name,
        ProviderStatus(state: LyricsProviderState.done, data: result),
      );
    } catch (e) {
      if (!mounted) return;
      ActivityLogService.w(
        'lyrics',
        '${name.name} failed for "${info.title}": $e',
      );
      _updateProviderStatus(
        name,
        ProviderStatus(state: LyricsProviderState.error, error: e.toString()),
      );
    }
  }

  void _updateProviderStatus(ProviderName name, ProviderStatus status) {
    if (!mounted) return;
    final newProviders = Map<ProviderName, ProviderStatus>.from(
      state.providers,
    );
    newProviders[name] = status;
    state = state.copyWith(providers: newProviders);

    // Auto-select if better provider available
    if (!state.hasManuallySwitched) {
      _selectBestProvider();
    }
  }

  /// Calculate provider bias/score (higher is better)
  int _providerBias(ProviderName name) {
    final status = state.providers[name];
    if (status == null) return -10;

    int bias = 0;

    // Provider is done loading
    if (status.state == LyricsProviderState.done) {
      bias += 1;
    } else if (status.state == LyricsProviderState.fetching) {
      bias -= 1;
    } else if (status.state == LyricsProviderState.error) {
      bias -= 2;
    }

    // Has synced lyrics (most valuable)
    if (status.data?.hasSyncedLyrics ?? false) bias += 3;

    // Has plain lyrics
    if (status.data?.hasPlainLyrics ?? false) bias += 1;

    // Word-level sync bonus (BetterLyrics karaoke)
    if (status.data?.hasWordSync ?? false) bias += 2;

    // Prefer BetterLyrics overall (highest quality)
    if (name == ProviderName.betterLyrics && (status.data?.hasLyrics ?? false)) {
      bias += 2;
    }

    // Prefer LRCLib overall if it has any lyrics
    if (name == ProviderName.lrclib && (status.data?.hasLyrics ?? false)) {
      bias += 1;
    }

    // Prefer YouTube Music if synced captions available
    if (name == ProviderName.youtubeMusic && (status.data?.hasSyncedLyrics ?? false)) {
      bias += 1;
    }

    // Prefer LRCLib for synced lyrics
    if (name == ProviderName.lrclib &&
        (status.data?.hasSyncedLyrics ?? false)) {
      bias += 1;
    }

    return bias;
  }

  /// Select the best provider based on bias
  void _selectBestProvider() {
    final sorted = List<ProviderName>.from(providerNames);
    sorted.sort((a, b) => _providerBias(b).compareTo(_providerBias(a)));

    final best = sorted.first;

    // Only switch if better than current
    if (_providerBias(best) > _providerBias(state.currentProvider)) {
      state = state.copyWith(currentProvider: best);
    }
  }

  /// Manually switch to next provider and fetch lyrics if not yet loaded
  Future<void> nextProvider() async {
    final currentIdx = providerNames.indexOf(state.currentProvider);
    final nextIdx = (currentIdx + 1) % providerNames.length;
    final next = providerNames[nextIdx];

    if (mounted) {
      state = state.copyWith(
        currentProvider: next,
        hasManuallySwitched: true,
      );
    }

    final status = state.providers[next];
    final needsFetch =
        status == null ||
        status.state == LyricsProviderState.idle ||
        (status.data == null && status.state != LyricsProviderState.fetching);

    if (needsFetch && _lastSearchInfo != null) {
      await _fetchFromProvider(next, _lastSearchInfo!);
      if (mounted) {
        _cacheBestResult(_lastSearchInfo!);
      }
    }
  }

  /// Manually switch to previous provider and fetch lyrics if not yet loaded
  Future<void> previousProvider() async {
    final currentIdx = providerNames.indexOf(state.currentProvider);
    final prevIdx =
        (currentIdx - 1 + providerNames.length) % providerNames.length;
    final prev = providerNames[prevIdx];

    if (mounted) {
      state = state.copyWith(
        currentProvider: prev,
        hasManuallySwitched: true,
      );
    }

    final status = state.providers[prev];
    final needsFetch =
        status == null ||
        status.state == LyricsProviderState.idle ||
        (status.data == null && status.state != LyricsProviderState.fetching);

    if (needsFetch && _lastSearchInfo != null) {
      await _fetchFromProvider(prev, _lastSearchInfo!);
      if (mounted) {
        _cacheBestResult(_lastSearchInfo!);
      }
    }
  }

  /// Clear lyrics
  void clear() {
    state = const LyricsState();
  }
}

/// Provider for lyrics service
final lyricsProvider = StateNotifierProvider<LyricsNotifier, LyricsState>((
  ref,
) {
  return LyricsNotifier();
});

/// Provider for current lyric line based on playback position
final currentLyricLineProvider = Provider<LyricLine?>((ref) {
  // Watch lyrics state to trigger rebuilds when lyrics change
  ref.watch(lyricsProvider);
  // This would need to be hooked up to position stream
  // For now returns null - will be connected in UI
  return null;
});
