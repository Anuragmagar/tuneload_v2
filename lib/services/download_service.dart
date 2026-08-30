import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:haudiotagger/haudiotagger.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import '../core/services/cache/hive_service.dart';
import '../core/utils/activity_log.dart';
import '../data/entities/download_entity.dart';
import '../data/entities/downloaded_playlist_entity.dart';
import '../data/entities/lyrics_entity.dart';
import 'playback/yt_player_utils.dart';
import 'playback/playback_data.dart';
import 'lyrics/lyrics_service.dart';
import 'notification_service.dart';
import 'local_music_scanner.dart';
import 'ytmusic_api_service.dart';

/// Comment embedded into downloaded files so listeners know their origin.
const String kDownloadComment = 'Downloaded from TuneLoad by ANURAG';

const String kDownloadQualityKey = 'download_quality';
const String kDownloadParallelPartCountKey = 'download_parallel_part_count';
const String kDownloadParallelMinSizeMbKey = 'download_parallel_min_size_mb';
const int kDefaultParallelDownloadPartCount = 4;
const int kMinParallelDownloadPartCount = 2;
const int kMaxParallelDownloadPartCount = 8;
const int kDefaultParallelDownloadMinSizeMb = 1;
const int kMinParallelDownloadMinSizeMb = 1;
const int kMaxParallelDownloadMinSizeMb = 32;
const int kMaxTransientDownloadRetries = 8;

/// Get downloads directory path - TuneLoad-style public folder
/// Path on Android: /storage/emulated/0/Download/TuneLoad/
Future<String> _getDownloadsDirPath() async {
  // Public Downloads/TuneLoad folder on Android (same as the primary app)
  if (Platform.isAndroid) {
    try {
      const path = '/storage/emulated/0/Download/TuneLoad';
      final downloadsDir = Directory(path);
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      return path;
    } catch (e) {
      if (kDebugMode) {
        print('DownloadService: Cannot use public Downloads folder: $e');
      }
    }
  }

  // Ultimate fallback: app documents directory
  final appDir = await getApplicationDocumentsDirectory();
  final downloadsDir = Directory('${appDir.path}/audio');
  if (!await downloadsDir.exists()) {
    await downloadsDir.create(recursive: true);
  }
  return downloadsDir.path;
}

/// Provider for download path - uses app-private storage
/// Returns the current download directory path
final downloadPathProvider = FutureProvider<String>((ref) async {
  return await _getDownloadsDirPath();
});

/// Provider for download quality preference
final downloadQualityProvider =
    StateNotifierProvider<DownloadQualityNotifier, AudioQuality>((ref) {
      return DownloadQualityNotifier();
    });

/// Provider for segmented parallel part count used by downloads.
final downloadParallelPartCountProvider =
    StateNotifierProvider<DownloadParallelPartCountNotifier, int>((ref) {
      return DownloadParallelPartCountNotifier();
    });

/// Provider for minimum file size (MB) before parallel segmented download is used.
final downloadParallelMinSizeMbProvider =
    StateNotifierProvider<DownloadParallelMinSizeMbNotifier, int>((ref) {
      return DownloadParallelMinSizeMbNotifier();
    });

/// Notifier for download quality
class DownloadQualityNotifier extends StateNotifier<AudioQuality> {
  DownloadQualityNotifier() : super(AudioQuality.high) {
    _loadQuality();
  }

  Future<void> _loadQuality() async {
    final prefs = await SharedPreferences.getInstance();
    final qualityIndex = prefs.getInt(kDownloadQualityKey);
    if (qualityIndex != null &&
        qualityIndex >= 0 &&
        qualityIndex < AudioQuality.values.length) {
      state = AudioQuality.values[qualityIndex];
    }
  }

  Future<void> setQuality(AudioQuality quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kDownloadQualityKey, quality.index);
    state = quality;
  }
}

/// Trigger to refresh downloaded tracks (incremented when downloads change)
final downloadedTracksRefreshProvider = StateProvider<int>((ref) => 0);
final downloadedPlaylistsRefreshProvider = StateProvider<int>((ref) => 0);

/// Provider for downloaded tracks (for display in library/songs tabs).
/// Sources every audio file physically present in the TuneLoad download
/// folder(s), enriched with persisted Hive metadata where available, so the
/// Songs page lists ALL downloaded songs - even files whose Hive record was
/// lost or that were added to the folder outside the in-app download flow.
final downloadedTracksProvider = FutureProvider<List<Track>>((ref) async {
  // Watch refresh trigger to auto-refresh when downloads change
  ref.watch(downloadedTracksRefreshProvider);

  // 1) Scan the download folder(s) recursively for audio files.
  try {
    final dirPath = await _getDownloadsDirPath();
    final scanned = await LocalMusicScanner.scanDirectory(dirPath);
    if (scanned.isNotEmpty) {
      // Deterministic "recently added" default order: newest file first.
      final sorted = List<Track>.from(scanned)
        ..sort((a, b) => _fileLastModifiedMs(b.localFilePath).compareTo(
              _fileLastModifiedMs(a.localFilePath),
            ));
      return sorted;
    }
  } catch (e) {
    if (kDebugMode) {
      print('DownloadService: Downloaded-folder scan failed: $e');
    }
  }

  // 2) Fallback: persisted Hive records whose files still exist.
  return _downloadedTracksFromHive();
});

/// Millisecond epoch of a file's last modification time (0 when unavailable).
int _fileLastModifiedMs(String? path) {
  if (path == null || path.isEmpty) return 0;
  try {
    return File(path).lastModifiedSync().millisecondsSinceEpoch;
  } catch (_) {
    return 0;
  }
}

/// Build the downloaded-track list from persisted Hive records (used as a
/// fallback when the folder scan comes up empty or is not permitted).
/// File existence checks run in a background isolate to avoid UI jank.
Future<List<Track>> _downloadedTracksFromHive() async {
  try {
    final box = HiveService.downloadsBox;

    // Collect download data for isolate processing
    final downloadData = box.values
        .map(
          (e) => _DownloadData(
            trackId: e.trackId,
            title: e.title,
            artist: e.artist,
            album: e.album,
            durationMs: e.durationMs,
            thumbnailUrl: e.thumbnailUrl,
            localPath: e.localPath,
          ),
        )
        .toList();

    // Verify file existence in isolate
    final validPaths = await compute(
      _verifyFilesExistIsolate,
      downloadData.map((d) => d.localPath).toList(),
    );

    final validPathSet = validPaths.toSet();

    // Build track list from valid downloads
    return downloadData
        .where((d) => validPathSet.contains(d.localPath))
        .map(
          (d) => Track(
            id: d.trackId,
            title: d.title,
            artist: d.artist,
            album: d.album,
            duration: Duration(milliseconds: d.durationMs),
            thumbnailUrl: d.thumbnailUrl,
            localFilePath: d.localPath,
          ),
        )
        .toList();
  } catch (e) {
    if (kDebugMode) {
      print('DownloadService: Failed to load downloaded tracks: $e');
    }
    return const <Track>[];
  }
}

class DownloadedPlaylistSnapshot {
  final String sourcePlaylistId;
  final String title;
  final String? thumbnailUrl;
  final int totalTracks;
  final int downloadedTracks;
  final List<Track> downloadedOrderedTracks;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DownloadedPlaylistSnapshot({
    required this.sourcePlaylistId,
    required this.title,
    this.thumbnailUrl,
    required this.totalTracks,
    required this.downloadedTracks,
    required this.downloadedOrderedTracks,
    required this.createdAt,
    required this.updatedAt,
  });
}

/// Provider for downloaded playlist snapshots with current download completion.
final downloadedPlaylistsProvider =
    FutureProvider<List<DownloadedPlaylistSnapshot>>((ref) async {
      ref.watch(downloadedPlaylistsRefreshProvider);
      ref.watch(downloadedTracksRefreshProvider);

      try {
        final playlists = HiveService.downloadedPlaylistsBox.values.toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

        final downloadsById = <String, DownloadEntity>{
          for (final e in HiveService.downloadsBox.values) e.trackId: e,
        };

        final snapshots = <DownloadedPlaylistSnapshot>[];
        for (final playlist in playlists) {
          final orderedTracks = <Track>[];
          for (final trackId in playlist.trackIds) {
            final download = downloadsById[trackId];
            if (download == null) continue;
            final localFile = File(download.localPath);
            if (!await localFile.exists()) continue;
            orderedTracks.add(
              Track(
                id: download.trackId,
                title: download.title,
                artist: download.artist,
                album: download.album,
                duration: Duration(milliseconds: download.durationMs),
                thumbnailUrl: download.thumbnailUrl,
                localFilePath: download.localPath,
              ),
            );
          }

          snapshots.add(
            DownloadedPlaylistSnapshot(
              sourcePlaylistId: playlist.sourcePlaylistId,
              title: playlist.title,
              thumbnailUrl: playlist.thumbnailUrl,
              totalTracks: playlist.trackIds.length,
              downloadedTracks: orderedTracks.length,
              downloadedOrderedTracks: orderedTracks,
              createdAt: playlist.createdAt,
              updatedAt: playlist.updatedAt,
            ),
          );
        }
        return snapshots;
      } catch (e) {
        if (kDebugMode) {
          print('DownloadService: Failed to load downloaded playlists: $e');
        }
        return const <DownloadedPlaylistSnapshot>[];
      }
    });

/// Data class for passing download info to isolate
class _DownloadData {
  final String trackId;
  final String title;
  final String artist;
  final String? album;
  final int durationMs;
  final String? thumbnailUrl;
  final String localPath;

  _DownloadData({
    required this.trackId,
    required this.title,
    required this.artist,
    this.album,
    required this.durationMs,
    this.thumbnailUrl,
    required this.localPath,
  });
}

/// Top-level isolate function to verify file existence
List<String> _verifyFilesExistIsolate(List<String> paths) {
  return paths.where((path) => File(path).existsSync()).toList();
}

/// Download status enum
enum DownloadStatus { queued, downloading, completed, failed, cancelled }

class _DownloadCancelledException implements Exception {
  const _DownloadCancelledException();

  @override
  String toString() => 'Download cancelled';
}

class DownloadParallelPartCountNotifier extends StateNotifier<int> {
  DownloadParallelPartCountNotifier()
    : super(kDefaultParallelDownloadPartCount) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value =
        prefs.getInt(kDownloadParallelPartCountKey) ??
        kDefaultParallelDownloadPartCount;
    state = value.clamp(
      kMinParallelDownloadPartCount,
      kMaxParallelDownloadPartCount,
    );
  }

  Future<void> setPartCount(int value) async {
    final clamped = value.clamp(
      kMinParallelDownloadPartCount,
      kMaxParallelDownloadPartCount,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kDownloadParallelPartCountKey, clamped);
    state = clamped;
  }
}

class DownloadParallelMinSizeMbNotifier extends StateNotifier<int> {
  DownloadParallelMinSizeMbNotifier()
    : super(kDefaultParallelDownloadMinSizeMb) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value =
        prefs.getInt(kDownloadParallelMinSizeMbKey) ??
        kDefaultParallelDownloadMinSizeMb;
    state = value.clamp(
      kMinParallelDownloadMinSizeMb,
      kMaxParallelDownloadMinSizeMb,
    );
  }

  Future<void> setMinSizeMb(int value) async {
    final clamped = value.clamp(
      kMinParallelDownloadMinSizeMb,
      kMaxParallelDownloadMinSizeMb,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kDownloadParallelMinSizeMbKey, clamped);
    state = clamped;
  }
}

/// Individual download task
class DownloadTask {
  final String trackId;
  final Track track;
  final DownloadStatus status;
  final double progress; // 0.0 to 1.0
  final int downloadedBytes;
  final int totalBytes;
  final String? error;
  final String? localPath;
  final DateTime startedAt;

  const DownloadTask({
    required this.trackId,
    required this.track,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.error,
    this.localPath,
    required this.startedAt,
  });

  DownloadTask copyWith({
    DownloadStatus? status,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    String? error,
    String? localPath,
  }) => DownloadTask(
    trackId: trackId,
    track: track,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    error: error ?? this.error,
    localPath: localPath ?? this.localPath,
    startedAt: startedAt,
  );

  String get progressText {
    if (totalBytes == 0) return '0%';
    return '${(progress * 100).toInt()}%';
  }

  String get sizeText {
    if (totalBytes == 0) return '';
    final mb = totalBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// Download manager state
class DownloadManagerState {
  final Map<String, DownloadTask> tasks;
  final List<String> queue; // Track IDs in download queue order
  final bool isDownloading;

  const DownloadManagerState({
    this.tasks = const {},
    this.queue = const [],
    this.isDownloading = false,
  });

  DownloadManagerState copyWith({
    Map<String, DownloadTask>? tasks,
    List<String>? queue,
    bool? isDownloading,
  }) => DownloadManagerState(
    tasks: tasks ?? this.tasks,
    queue: queue ?? this.queue,
    isDownloading: isDownloading ?? this.isDownloading,
  );

  List<DownloadTask> get activeTasks => tasks.values
      .where((t) => t.status == DownloadStatus.downloading)
      .toList();

  List<DownloadTask> get queuedTasks =>
      tasks.values.where((t) => t.status == DownloadStatus.queued).toList();

  List<DownloadTask> get completedTasks =>
      tasks.values.where((t) => t.status == DownloadStatus.completed).toList();

  List<DownloadTask> get failedTasks =>
      tasks.values.where((t) => t.status == DownloadStatus.failed).toList();

  int get totalCompleted => completedTasks.length;

  int get totalStorageBytes =>
      completedTasks.fold(0, (sum, t) => sum + t.totalBytes);

  String get totalStorageText {
    final mb = totalStorageBytes / (1024 * 1024);
    if (mb > 1024) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// Download manager notifier
class DownloadManagerNotifier extends StateNotifier<DownloadManagerState> {
  final YTPlayerUtils _playerUtils;
  final Ref _ref;
  final DownloadNotificationService _notificationService =
      DownloadNotificationService();
  http.Client? _httpClient;
  StreamSubscription? _currentDownload;
  DateTime? _lastNotificationUpdate;
  bool _initialized = false;
  AudioQuality _downloadQuality = AudioQuality.high;
  int _parallelDownloadPartCount = kDefaultParallelDownloadPartCount;
  int _parallelDownloadMinBytes =
      kDefaultParallelDownloadMinSizeMb * 1024 * 1024;
  Timer? _cleanupTimer;
  final Map<String, int> _transientRetryAttempts = <String, int>{};
  InnerTubeService? _innerTube;

  InnerTubeService get _ytApi => _innerTube ??= InnerTubeService();

  DownloadManagerNotifier(this._playerUtils, this._ref)
    : super(const DownloadManagerState()) {
    // Initialize notification service
    _notificationService.initialize();
    // Load persisted downloads
    _loadPersistedDownloads();
    // Load download quality preference
    _loadDownloadQuality();
    // Load parallel download tuning settings.
    _loadParallelDownloadSettings();
    // Start cleanup timer (runs every 30 minutes)
    _cleanupTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _cleanupOldCompletedTasks(),
    );
  }

  /// Load download quality from preferences
  Future<void> _loadDownloadQuality() async {
    final prefs = await SharedPreferences.getInstance();
    final qualityIndex = prefs.getInt(kDownloadQualityKey);
    if (qualityIndex != null &&
        qualityIndex >= 0 &&
        qualityIndex < AudioQuality.values.length) {
      _downloadQuality = AudioQuality.values[qualityIndex];
    }
  }

  /// Set download quality (called from provider)
  void setDownloadQuality(AudioQuality quality) {
    _downloadQuality = quality;
  }

  Future<void> _loadParallelDownloadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final partCount =
        prefs.getInt(kDownloadParallelPartCountKey) ??
        kDefaultParallelDownloadPartCount;
    final minSizeMb =
        prefs.getInt(kDownloadParallelMinSizeMbKey) ??
        kDefaultParallelDownloadMinSizeMb;
    _parallelDownloadPartCount = partCount.clamp(
      kMinParallelDownloadPartCount,
      kMaxParallelDownloadPartCount,
    );
    final clampedMinSizeMb = minSizeMb.clamp(
      kMinParallelDownloadMinSizeMb,
      kMaxParallelDownloadMinSizeMb,
    );
    _parallelDownloadMinBytes = clampedMinSizeMb * 1024 * 1024;
  }

  void setParallelDownloadPartCount(int value) {
    _parallelDownloadPartCount = value.clamp(
      kMinParallelDownloadPartCount,
      kMaxParallelDownloadPartCount,
    );
  }

  void setParallelDownloadMinSizeMb(int value) {
    final clamped = value.clamp(
      kMinParallelDownloadMinSizeMb,
      kMaxParallelDownloadMinSizeMb,
    );
    _parallelDownloadMinBytes = clamped * 1024 * 1024;
  }

  /// Get downloads directory - TuneLoad-style public Downloads folder
  Future<Directory> getDownloadsDir() async {
    final path = await _getDownloadsDirPath();
    return Directory(path);
  }

  static const MethodChannel _mediaScannerChannel =
      MethodChannel('inzx/media_scan');

  /// Ask Android's MediaScanner to index a file so it shows up in other apps
  /// (music players, file managers) after the download finishes.
  Future<void> _notifyMediaScanner(String filePath) async {
    if (!Platform.isAndroid) return;
    try {
      await _mediaScannerChannel.invokeMethod<void>('scanFile', {
        'path': filePath,
      });
      ActivityLogService.i('download', 'Media scanner indexed "$filePath"');
    } catch (e) {
      ActivityLogService.w('download', 'Media scan failed for "$filePath": $e');
      if (kDebugMode) {
        print('DownloadService: Media scan failed: $e');
      }
    }
  }

  /// Convert a downloaded file to M4A/AAC with embedded metadata (title,
  /// artist, album, comment, year, track/disc numbers, lyrics and cover art)
  /// so it shows up correctly in other music apps. Returns the new path on
  /// success, or null to keep the original.
  Future<String?> _convertToM4a(DownloadTask task, String sourcePath) async {
    if (!Platform.isAndroid) return null;

    // Resolve rich tag metadata (album, year, track/disc numbers) from the
    // YouTube Music API when the song row didn't carry it. Best-effort and
    // bounded; never fails the download.
    final meta = await _resolveDownloadMetadata(task);

    try {
      final dotIndex = sourcePath.lastIndexOf('.');
      if (dotIndex <= 0) return null;
      final outputPath = '${sourcePath.substring(0, dotIndex)}.m4a';

      ActivityLogService.i('convert', 'Converting "${task.track.title}" to M4A/AAC...');

      final coverPath = '$sourcePath.cover.jpg';
      final hasCover = await File(coverPath).exists();

      // Raw argv - no quoting needed (executeWithArguments passes args to
      // ffmpeg directly, so spaces/apostrophes/newlines in values are safe).
      final arguments = <String>['-y', '-i', sourcePath];
      if (hasCover) {
        arguments.addAll(['-i', coverPath]);
      }
      arguments.addAll([
        '-map',
        '0:a:0',
        '-acodec',
        'aac',
        '-b:a',
        switch (_downloadQuality) {
          AudioQuality.low => '96k',
          AudioQuality.medium => '128k',
          AudioQuality.high => '192k',
          AudioQuality.max => '256k',
          AudioQuality.auto => '160k',
        },
        '-metadata',
        'title=${task.track.title}',
        '-metadata',
        'artist=${task.track.artist.isNotEmpty ? task.track.artist : 'Unknown Artist'}',
        '-metadata',
        'album_artist=${task.track.artist.isNotEmpty ? task.track.artist : 'Unknown Artist'}',
      ]);
      final albumName = meta.album?.trim();
      if (albumName != null && albumName.isNotEmpty) {
        arguments.addAll(['-metadata', 'album=$albumName']);
      }
      // Year → the "date" tag (written as ©day in M4A).
      if (meta.year != null && meta.year! > 0) {
        arguments.addAll(['-metadata', 'date=${meta.year}']);
      }
      // Track/disk numbers in the "num/total" form ffmpeg folds into the
      // iTunes-style trkn/disk atoms.
      final trackNumber = meta.trackNumber;
      final trackTotal = meta.trackTotal;
      if (trackNumber != null || trackTotal != null) {
        arguments.addAll([
          '-metadata',
          'track=${trackNumber ?? ''}${trackTotal != null ? '/$trackTotal' : ''}',
        ]);
      }
      final discNumber = meta.discNumber;
      final discTotal = meta.discTotal;
      if (discNumber != null || discTotal != null) {
        arguments.addAll([
          '-metadata',
          'disc=${discNumber ?? ''}${discTotal != null ? '/$discTotal' : ''}',
        ]);
      }
      // Comment identifying the downloader/version for listeners.
      arguments.addAll(['-metadata', 'comment=$kDownloadComment']);
      // Embed the lyrics (written to the "©lyr" tag in M4A) so downloaded
      // songs show lyrics in other players too.
      final lyrics = await _resolveLyricsForTag(task);
      if (lyrics != null && lyrics.isNotEmpty) {
        arguments.addAll(['-metadata', 'lyrics=$lyrics']);
        ActivityLogService.d('convert', 'Lyrics embedded for "${task.track.title}"');
      } else if (kDebugMode) {
        print('DownloadService: No lyrics found to embed for ${task.trackId}');
      }
      if (hasCover) {
        arguments.addAll([
          '-map',
          '1:v:0',
          '-c:v',
          'mjpeg',
          '-disposition:v',
          'attached_pic',
        ]);
      } else {
        arguments.add('-vn');
      }
      arguments.addAll(['-movflags', '+faststart', outputPath]);

      final session = await FFmpegKit.executeWithArguments(arguments);
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        ActivityLogService.e(
          'convert',
          'M4A conversion failed for "${task.track.title}" ($returnCode), keeping original',
        );
        if (kDebugMode) {
          print(
            'DownloadService: M4A conversion failed ($returnCode), keeping original',
          );
        }
        return null;
      }

      final output = File(outputPath);
      if (!await output.exists() || await output.length() < 1024) {
        ActivityLogService.w(
          'convert',
          'M4A conversion produced invalid output for "${task.track.title}"',
        );
        if (kDebugMode) {
          print('DownloadService: M4A conversion produced invalid output');
        }
        return null;
      }

      ActivityLogService.success('convert', 'Converted "${task.track.title}" to M4A');
      if (kDebugMode) {
        print('DownloadService: Converted ${task.track.title} to M4A');
      }

      // Replace the original file with the tagged M4A version.
      await File(sourcePath).delete();

      // Write the tags with haudiotagger (Rust/lofty) so the lyrics land in a
      // real iTunes-style "©lyr" tag that other players actually read.
      await _writeTagsViaHaudiotagger(task, outputPath, lyrics, meta);

      // Keep the cover art next to the converted file (used for offline now
      // playing artwork). Non-fatal: the M4A already embeds its own cover.
      final newCoverPath = '$outputPath.cover.jpg';
      if (await File(coverPath).exists()) {
        try {
          await File(coverPath).rename(newCoverPath);
        } catch (e) {
          if (kDebugMode) {
            print('DownloadService: Could not move cover art: $e');
          }
        }
      }
      return outputPath;
    } catch (e) {
      if (kDebugMode) {
        print('DownloadService: M4A conversion error: $e');
      }
      return null;
    }
  }

  /// Write the final tags onto the converted M4A via haudiotagger so the
  /// lyrics are stored in a proper iTunes-style "©lyr" tag. Non-fatal: the
  /// download already succeeded, tagging is best-effort.
  Future<void> _writeTagsViaHaudiotagger(
    DownloadTask task,
    String filePath,
    String? lyrics,
    ({
      String? album,
      String? albumId,
      int? year,
      String? genre,
      int? trackNumber,
      int? trackTotal,
      int? discNumber,
      int? discTotal,
    }) meta,
  ) async {
    try {
      final changes = TagChanges(
        title: task.track.title,
        trackArtist: task.track.artist.isNotEmpty
            ? task.track.artist
            : 'Unknown Artist',
        albumArtist: task.track.artist.isNotEmpty
            ? task.track.artist
            : 'Unknown Artist',
        album: meta.album != null && meta.album!.trim().isNotEmpty
            ? meta.album
            : null,
        year: meta.year,
        genre: meta.genre,
        trackNumber: meta.trackNumber,
        trackTotal: meta.trackTotal,
        discNumber: meta.discNumber,
        discTotal: meta.discTotal,
        lyrics: lyrics != null && lyrics.isNotEmpty ? lyrics : null,
        comment: kDownloadComment,
      );
      await Haudiotagger.update(filePath, changes);
      ActivityLogService.success(
        'tag',
        'Tags written on "$filePath"${lyrics != null && lyrics.isNotEmpty ? ' + lyrics' : ''}',
      );
      if (kDebugMode) {
        print('DownloadService: Tags written via haudiotagger');
      }
    } catch (e) {
      ActivityLogService.w('tag', 'haudiotagger tag write failed: $e');
      if (kDebugMode) {
        print('DownloadService: haudiotagger tag write failed: $e');
      }
    }
  }

  /// Best-effort rich tag metadata for a download (album, year, track/disc
  /// numbers). Uses whatever the song row already carried, then asks the
  /// YouTube Music API for anything still missing. Bounded (~8s) and non-fatal.
  Future<
      ({
        String? album,
        String? albumId,
        int? year,
        String? genre,
        int? trackNumber,
        int? trackTotal,
        int? discNumber,
        int? discTotal,
      })> _resolveDownloadMetadata(DownloadTask task) async {
    final track = task.track;
    final hasAlbum = track.album != null && track.album!.trim().isNotEmpty;
    try {
      final resolved = await _ytApi.resolveTrackMetadata(track).timeout(
            const Duration(seconds: 8),
          );
      return (
        album: resolved.album != null && resolved.album!.trim().isNotEmpty
            ? resolved.album
            : track.album,
        albumId: resolved.albumId != null && resolved.albumId!.isNotEmpty
            ? resolved.albumId
            : track.albumId,
        year: resolved.year ?? track.year,
        genre: resolved.genre ?? track.genre,
        trackNumber: resolved.trackNumber ?? track.trackNumber,
        trackTotal: resolved.trackTotal ?? track.trackTotal,
        discNumber: resolved.discNumber ?? track.discNumber,
        discTotal: resolved.discTotal ?? track.discTotal,
      );
    } catch (e) {
      if (kDebugMode) {
        print(
          'DownloadService: Metadata resolution failed for "${track.title}": $e',
        );
      }
      return (
        album: hasAlbum ? track.album : null,
        albumId: track.albumId,
        year: track.year,
        genre: track.genre,
        trackNumber: track.trackNumber,
        trackTotal: track.trackTotal,
        discNumber: track.discNumber,
        discTotal: track.discTotal,
      );
    }
  }

  /// Best-effort plain-text lyrics for embedding into the M4A tag.
  /// Uses the download-time prefetched/cached lyrics; fires a fetch if missing
  /// and polls the Hive cache (the warm-up service dedupes in-flight fetches,
  /// so we wait for the cache to fill rather than awaiting the fetch itself).
  /// Bounded (~12s) so a slow lyrics provider never stalls the download.
  Future<String?> _resolveLyricsForTag(DownloadTask task) async {
    try {
      LyricsEntity? entity;
      try {
        entity = HiveService.lyricsBox.get(task.trackId);
      } catch (_) {
        entity = null;
      }

      if (entity == null || !entity.hasLyrics) {
        unawaited(
          LyricsWarmupService.instance
              .prefetchForTrack(
                videoId: task.trackId,
                title: task.track.title,
                artist: task.track.artist,
                album: task.track.album,
                durationSeconds: task.track.duration.inSeconds,
              )
              .catchError((_) {}),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        while (DateTime.now().isBefore(deadline)) {
          try {
            entity = HiveService.lyricsBox.get(task.trackId);
          } catch (_) {
            entity = null;
          }
          if (entity != null && entity.hasLyrics) break;
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }

      if (entity == null || !entity.hasLyrics) return null;
      // Prefer synced lyrics so their timestamps survive embedding: a synced
      // lyric must not be flattened into an unsynced one. Only fall back to
      // plain text when no timed lines are available.
      if (entity.hasSyncedLyrics) {
        final timed = _keepTimedLrcLines(entity.syncedLyrics!);
        if (timed.isNotEmpty) return timed;
      }
      if (entity.hasPlainLyrics) return entity.plainLyrics!.trim();
      if (entity.hasSyncedLyrics) {
        return _stripLrcTimestamps(entity.syncedLyrics!);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Keep only timed LRC lines (`[mm:ss.xx] ...`), dropping metadata headers
  /// like `[ti:]`, `[ar:]` and empty lines. Preserves the synced classification
  /// so players that parse LRC can scroll the lyrics in sync.
  String _keepTimedLrcLines(String lrc) {
    final timed = lrc
        .split('\n')
        .map((line) => line.trim())
        .where((line) => RegExp(r'^\[\d+:\d+\.\d+\]').hasMatch(line))
        .toList();
    return timed.join('\n');
  }

  /// Remove [mm:ss.xx] timestamps from an LRC string, keeping the text lines.
  String _stripLrcTimestamps(String lrc) {
    return lrc
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  /// Human-readable byte size, e.g. 4.2 MB.
  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = value >= 100 ? value.round().toString() : value.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }

  /// Ensure we can write to the public Downloads/TuneLoad folder.
  /// On Android 11+ this needs "All files access" (MANAGE_EXTERNAL_STORAGE);
  /// on Android 10 and below it needs the storage permission.
  Future<bool> _ensureDownloadStoragePermission() async {
    if (!Platform.isAndroid) return true;

    try {
      // Android 11+: MANAGE_EXTERNAL_STORAGE (requests "All files access")
      final manageStatus = await Permission.manageExternalStorage.request();
      if (manageStatus.isGranted) return true;

      // Android 10 and below: READ/WRITE storage permission
      final storageStatus = await Permission.storage.request();
      if (storageStatus.isGranted) return true;

      return false;
    } catch (e) {
      if (kDebugMode) {
        print('DownloadService: Failed to request storage permission: $e');
      }
      return false;
    }
  }

  /// Legacy getter for backward compatibility
  Future<Directory> get _downloadsDir => getDownloadsDir();

  /// Load persisted download metadata from Hive
  Future<void> _loadPersistedDownloads() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final downloadsBox = HiveService.downloadsBox;
      final tasks = <String, DownloadTask>{};

      for (final entity in downloadsBox.values) {
        final localPath = entity.localPath;

        // Only restore if file still exists
        if (await File(localPath).exists()) {
          final track = Track(
            id: entity.trackId,
            title: entity.title,
            artist: entity.artist,
            album: entity.album,
            duration: Duration(milliseconds: entity.durationMs),
            thumbnailUrl: entity.thumbnailUrl,
            localFilePath: localPath,
          );

          tasks[entity.trackId] = DownloadTask(
            trackId: entity.trackId,
            track: track,
            status: DownloadStatus.completed,
            progress: 1.0,
            totalBytes: entity.totalBytes,
            downloadedBytes: entity.totalBytes,
            localPath: localPath,
            startedAt: entity.downloadedAt,
          );
        } else {
          // File no longer exists, remove from Hive
          await downloadsBox.delete(entity.trackId);
        }
      }

      if (tasks.isNotEmpty) {
        state = state.copyWith(tasks: tasks);
        if (kDebugMode) {
          print(
            'DownloadService: Loaded ${tasks.length} persisted downloads from Hive',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('DownloadService: Failed to load persisted downloads: $e');
      }
    }
  }

  /// Persist completed download to Hive
  Future<void> _persistDownload(DownloadTask task) async {
    try {
      final entity = DownloadEntity(
        trackId: task.trackId,
        title: task.track.title,
        artist: task.track.artist,
        album: task.track.album,
        durationMs: task.track.duration.inMilliseconds,
        thumbnailUrl: task.track.thumbnailUrl,
        localPath: task.localPath!,
        totalBytes: task.totalBytes,
        downloadedAt: DateTime.now(),
        quality: _downloadQuality.name,
      );

      await HiveService.downloadsBox.put(task.trackId, entity);
      if (kDebugMode) {
        print('DownloadService: Persisted download ${task.trackId} to Hive');
      }
    } catch (e) {
      if (kDebugMode) {
        print('DownloadService: Failed to persist download: $e');
      }
    }
  }

  /// Remove download from Hive
  Future<void> _removeFromHive(String trackId) async {
    try {
      await HiveService.downloadsBox.delete(trackId);
    } catch (e) {
      if (kDebugMode) {
        print('DownloadService: Failed to remove from Hive: $e');
      }
    }
  }

  /// Add track to download queue
  Future<void> addToQueue(Track track) async {
    if (!await _ensureDownloadStoragePermission()) return;

    if (state.tasks.containsKey(track.id)) {
      final existing = state.tasks[track.id]!;
      if (existing.status == DownloadStatus.completed) {
        return; // Already downloaded
      }
      if (existing.status == DownloadStatus.downloading ||
          existing.status == DownloadStatus.queued) {
        return; // Already in progress
      }
    }

    final task = DownloadTask(
      trackId: track.id,
      track: track,
      status: DownloadStatus.queued,
      startedAt: DateTime.now(),
    );

    final newTasks = Map<String, DownloadTask>.from(state.tasks);
    newTasks[track.id] = task;

    final newQueue = List<String>.from(state.queue);
    newQueue.add(track.id);

    state = state.copyWith(tasks: newTasks, queue: newQueue);

    ActivityLogService.i(
      'download',
      'Queued "${track.title}" by ${track.artist}',
    );

    // Prefetch and cache lyrics alongside the download so they're available
    // offline in the scrolling lyrics view and other players.
    unawaited(
      LyricsWarmupService.instance.prefetchForTrack(
        videoId: track.id,
        title: track.title,
        artist: track.artist,
        album: track.album,
        durationSeconds: track.duration.inSeconds,
      ),
    );

    // Start download if not already downloading
    _processQueue();
  }

  /// Add multiple tracks to queue
  Future<void> addMultipleToQueue(List<Track> tracks) async {
    for (final track in tracks) {
      await addToQueue(track);
    }
  }

  /// Create/update a downloaded-playlist snapshot and enqueue its tracks.
  Future<void> addPlaylistToQueue({
    required String sourcePlaylistId,
    required String title,
    String? thumbnailUrl,
    required List<Track> tracks,
  }) async {
    if (tracks.isEmpty) return;
    await _upsertDownloadedPlaylistSnapshot(
      sourcePlaylistId: sourcePlaylistId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      tracks: tracks,
    );
    await addMultipleToQueue(tracks);
  }

  Future<void> _upsertDownloadedPlaylistSnapshot({
    required String sourcePlaylistId,
    required String title,
    String? thumbnailUrl,
    required List<Track> tracks,
  }) async {
    final normalizedId = sourcePlaylistId.trim().isEmpty
        ? 'playlist_${title.hashCode}'
        : sourcePlaylistId.trim();

    final trackIds = tracks.map((t) => t.id).toList(growable: false);
    final trackTitles = <String, String>{for (final t in tracks) t.id: t.title};
    final trackArtists = <String, String>{
      for (final t in tracks) t.id: t.artist,
    };

    final box = HiveService.downloadedPlaylistsBox;
    final existing = box.get(normalizedId);
    final now = DateTime.now();
    final entity = DownloadedPlaylistEntity(
      sourcePlaylistId: normalizedId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      trackIds: trackIds,
      trackTitles: trackTitles,
      trackArtists: trackArtists,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await box.put(normalizedId, entity);
    _ref.read(downloadedPlaylistsRefreshProvider.notifier).state++;
  }

  /// Cancel a download
  void cancelDownload(String trackId) {
    if (!state.tasks.containsKey(trackId)) return;
    _transientRetryAttempts.remove(trackId);

    final task = state.tasks[trackId]!;
    if (task.status == DownloadStatus.downloading) {
      _currentDownload?.cancel();
    }

    // Cancel notification
    _notificationService.cancelNotification(trackId);

    final newTasks = Map<String, DownloadTask>.from(state.tasks);
    newTasks[trackId] = task.copyWith(status: DownloadStatus.cancelled);

    final newQueue = List<String>.from(state.queue);
    newQueue.remove(trackId);

    state = state.copyWith(
      tasks: newTasks,
      queue: newQueue,
      isDownloading: false,
    );

    _processQueue();
  }

  /// Remove a completed/failed download
  Future<void> removeDownload(String trackId) async {
    if (!state.tasks.containsKey(trackId)) return;
    _transientRetryAttempts.remove(trackId);

    final task = state.tasks[trackId]!;

    // Delete file if exists
    if (task.localPath != null) {
      try {
        final file = File(task.localPath!);
        if (await file.exists()) {
          await file.delete();
          if (kDebugMode) {
            print('DownloadService: Deleted file: ${task.localPath}');
          }
        }
        final coverFile = File('${task.localPath!}.cover.jpg');
        if (await coverFile.exists()) {
          await coverFile.delete();
          if (kDebugMode) {
            print('DownloadService: Deleted cover: ${coverFile.path}');
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('Error deleting file: $e');
        }
      }
    }

    final newTasks = Map<String, DownloadTask>.from(state.tasks);
    newTasks.remove(trackId);

    final newQueue = List<String>.from(state.queue);
    newQueue.remove(trackId);

    state = state.copyWith(tasks: newTasks, queue: newQueue);

    // Remove from Hive
    await _removeFromHive(trackId);

    // Trigger refresh of downloaded tracks provider
    _ref.read(downloadedTracksRefreshProvider.notifier).state++;
  }

  /// Remove all downloaded tracks
  Future<void> removeAllDownloads() async {
    final trackIds = state.tasks.keys.toList();
    for (final id in trackIds) {
      await removeDownload(id);
    }
  }

  /// Retry a failed download
  void retryDownload(String trackId) {
    if (!state.tasks.containsKey(trackId)) return;

    final task = state.tasks[trackId]!;
    if (task.status != DownloadStatus.failed) return;
    _transientRetryAttempts.remove(trackId);

    final newTasks = Map<String, DownloadTask>.from(state.tasks);
    newTasks[trackId] = task.copyWith(
      status: DownloadStatus.queued,
      progress: 0,
      downloadedBytes: 0,
      error: null,
    );

    final newQueue = List<String>.from(state.queue);
    newQueue.add(trackId);

    state = state.copyWith(tasks: newTasks, queue: newQueue);

    _processQueue();
  }

  /// Check if a track is downloaded
  bool isDownloaded(String trackId) {
    final task = state.tasks[trackId];
    return task?.status == DownloadStatus.completed && task?.localPath != null;
  }

  /// Get local path for a downloaded track
  String? getLocalPath(String trackId) {
    final task = state.tasks[trackId];
    if (task?.status == DownloadStatus.completed) {
      return task?.localPath;
    }
    return null;
  }

  /// Process download queue
  void _processQueue() {
    if (state.isDownloading) return;
    if (state.queue.isEmpty) return;

    final nextTrackId = state.queue.first;
    final task = state.tasks[nextTrackId];
    if (task == null) return;

    _downloadTrack(task);
  }

  bool _isTaskCancelled(String trackId) {
    final task = state.tasks[trackId];
    return task?.status == DownloadStatus.cancelled;
  }

  bool _isTransientDownloadError(Object error) {
    if (error is SocketException ||
        error is HttpException ||
        error is TimeoutException ||
        error is HandshakeException) {
      return true;
    }

    final message = error.toString().toLowerCase();
    const transientHints = <String>[
      'socketexception',
      'timed out',
      'connection reset',
      'connection aborted',
      'network is unreachable',
      'software caused connection abort',
      'failed host lookup',
      'handshake',
      'temporarily unavailable',
      'connection closed before full header was received',
    ];

    for (final hint in transientHints) {
      if (message.contains(hint)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _downloadCoverArtForTrack({
    required String trackId,
    required String? thumbnailUrl,
    required String audioFilePath,
  }) async {
    final rawUrl = thumbnailUrl?.trim();
    if (rawUrl == null || rawUrl.isEmpty) return;

    final candidates = <String>[
      rawUrl.replaceAll('w120-h120', 'w600-h600'),
      rawUrl,
    ];
    final tried = <String>{};
    final coverFile = File('$audioFilePath.cover.jpg');

    for (final url in candidates) {
      final candidate = url.trim();
      if (candidate.isEmpty || !tried.add(candidate)) continue;
      try {
        final uri = Uri.tryParse(candidate);
        if (uri == null) continue;

        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 12);
        try {
          final request = await client.getUrl(uri);
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          request.headers.set(HttpHeaders.connectionHeader, 'close');
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) continue;

          final bytesBuilder = BytesBuilder(copy: false);
          await for (final chunk in response) {
            if (_isTaskCancelled(trackId)) {
              throw const _DownloadCancelledException();
            }
            bytesBuilder.add(chunk);
          }

          final bytes = bytesBuilder.takeBytes();
          if (bytes.length < 1024) continue;
          await coverFile.writeAsBytes(bytes, flush: true);
          if (kDebugMode) {
            print(
              'DownloadService: Saved cover art for $trackId (${(bytes.length / 1024).toStringAsFixed(1)} KB)',
            );
          }
          return;
        } finally {
          client.close(force: true);
        }
      } on _DownloadCancelledException {
        rethrow;
      } catch (_) {
        // Try next candidate URL.
      }
    }

    if (kDebugMode) {
      print('DownloadService: Could not save cover art for $trackId');
    }
  }

  Future<int?> _downloadWithParallelRanges({
    required String trackId,
    required Uri streamUri,
    required File outputFile,
    required int expectedBytes,
    required void Function(int downloadedBytes) onProgress,
  }) async {
    if (_parallelDownloadPartCount < kMinParallelDownloadPartCount) {
      return null;
    }
    if (expectedBytes < _parallelDownloadMinBytes) {
      return null;
    }

    final partCount = min(
      _parallelDownloadPartCount,
      max(2, expectedBytes ~/ (512 * 1024)),
    );

    final parts = <({int start, int end, File file})>[];
    int cursor = 0;
    final basePartSize = expectedBytes ~/ partCount;
    final remainder = expectedBytes % partCount;
    for (int i = 0; i < partCount; i++) {
      final partSize = basePartSize + (i < remainder ? 1 : 0);
      final start = cursor;
      final end = start + partSize - 1;
      cursor = end + 1;
      parts.add((
        start: start,
        end: end,
        file: File('${outputFile.path}.seg$i.part'),
      ));
    }

    if (kDebugMode) {
      print(
        'DownloadService: Trying parallel download for $trackId '
        '($expectedBytes bytes, parts=$partCount)',
      );
    }

    int downloadedBytes = 0;

    Future<void> cleanupParts() async {
      for (final part in parts) {
        if (await part.file.exists()) {
          await part.file.delete();
        }
      }
    }

    try {
      for (final part in parts) {
        if (await part.file.exists()) {
          await part.file.delete();
        }
      }

      Future<void> downloadPart(({int start, int end, File file}) part) async {
        if (_isTaskCancelled(trackId)) {
          throw const _DownloadCancelledException();
        }
        HttpClient? partClient;
        IOSink? partSink;
        try {
          partClient = HttpClient()
            ..connectionTimeout = const Duration(seconds: 20);
          final request = await partClient.getUrl(streamUri);
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          request.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
          request.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=${part.start}-${part.end}',
          );

          final response = await request.close();
          if (response.statusCode != 206) {
            throw HttpException(
              'Range request returned HTTP ${response.statusCode}',
            );
          }

          partSink = part.file.openWrite(mode: FileMode.writeOnly);
          int partBytes = 0;
          await for (final chunk in response) {
            if (_isTaskCancelled(trackId)) {
              throw const _DownloadCancelledException();
            }
            partSink.add(chunk);
            partBytes += chunk.length;
            downloadedBytes += chunk.length;
            onProgress(downloadedBytes);
          }

          await partSink.flush();
          await partSink.close();
          partSink = null;

          final expectedPartBytes = part.end - part.start + 1;
          if (partBytes != expectedPartBytes) {
            throw FormatException(
              'Range part size mismatch ($partBytes vs $expectedPartBytes)',
            );
          }
        } finally {
          if (partSink != null) {
            await partSink.close();
          }
          partClient?.close(force: true);
        }
      }

      await Future.wait(parts.map(downloadPart));

      if (_isTaskCancelled(trackId)) {
        throw const _DownloadCancelledException();
      }

      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      final mergeSink = outputFile.openWrite(mode: FileMode.writeOnly);
      try {
        for (final part in parts) {
          await mergeSink.addStream(part.file.openRead());
        }
        await mergeSink.flush();
      } finally {
        await mergeSink.close();
      }

      final mergedBytes = await outputFile.length();
      if (mergedBytes != expectedBytes) {
        throw FormatException(
          'Merged range file size mismatch ($mergedBytes vs $expectedBytes)',
        );
      }

      await cleanupParts();
      return mergedBytes;
    } catch (e) {
      await cleanupParts();
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      if (e is _DownloadCancelledException) {
        rethrow;
      }
      if (kDebugMode) {
        print('DownloadService: Parallel download fallback for $trackId: $e');
      }
      return null;
    }
  }

  /// Download a single track using range-based continuation (OuterTune style)
  /// YouTube serves chunked streams that may not complete in a single GET request
  Future<void> _downloadTrack(DownloadTask task) async {
    state = state.copyWith(isDownloading: true);

    // Update status to downloading
    _updateTask(
      task.trackId,
      task.copyWith(status: DownloadStatus.downloading),
    );

    ActivityLogService.i(
      'download',
      'Downloading "${task.track.title}"...',
    );

    // Show download started notification
    await _notificationService.showDownloadStarted(
      task.trackId,
      task.track.title,
    );

    try {
      // Get stream format - prefer Opus/WebM (more reliable for YouTube downloads)
      final result = await _playerUtils.playerResponseForDownload(
        task.trackId,
        quality: _downloadQuality,
      );
      if (result.isFailure || result.data == null) {
        throw Exception(result.error ?? 'Failed to get stream URL');
      }

      final streamUrl = result.data!.streamUrl;
      final format = result.data!.format;

      // Determine correct file extension based on actual format
      String extension = '.opus'; // Default - prefer Opus
      if (format.mimeType.contains('mp4') || format.mimeType.contains('m4a')) {
        extension = '.m4a';
      } else if (format.mimeType.contains('webm') ||
          format.mimeType.contains('opus')) {
        extension = '.opus';
      }

      if (kDebugMode) {
        print('DownloadService: Downloading ${format.mimeType} as $extension');
      }

      // Create file with proper naming: "Artist - Title.ext"
      final dir = await _downloadsDir;
      final fileName = _downloadedFileName(task.track, extension);
      final filePath = '${dir.path}/$fileName';
      final file = File(filePath);

      // === DOWNLOAD STRATEGY ===
      // 1) Try segmented parallel range download when content length is known.
      // 2) Fallback to the existing robust sequential + range continuation flow.
      int totalDownloaded = 0;
      int expectedTotal = result.data!.format.contentLength ?? 0;
      int retryCount = 0;
      const maxRetries = 5;
      const maxRangeAttempts = 10; // Max range continuation attempts
      bool downloadedWithParallel = false;
      DateTime lastProgressUpdate = DateTime.now();
      int lastLoggedPct = 0;

      void reportProgress({bool force = false}) {
        final now = DateTime.now();
        if (!force &&
            now.difference(lastProgressUpdate).inMilliseconds <= 100) {
          return;
        }
        lastProgressUpdate = now;
        final progress = expectedTotal > 0
            ? (totalDownloaded / expectedTotal).clamp(0.0, 1.0)
            : 0.0;
        _updateTask(
          task.trackId,
          task.copyWith(
            status: DownloadStatus.downloading,
            progress: progress,
            downloadedBytes: totalDownloaded,
            totalBytes: expectedTotal,
          ),
        );
        // Log coarse milestones only, to keep the terminal useful not noisy.
        final pct = (progress * 100).round();
        if (pct >= lastLoggedPct + 25) {
          lastLoggedPct = pct;
          ActivityLogService.i(
            'download',
            '"${task.track.title}" $pct% ($_fmtBytes(totalDownloaded))',
          );
        }
        if (force ||
            _lastNotificationUpdate == null ||
            now.difference(_lastNotificationUpdate!).inMilliseconds > 500) {
          _lastNotificationUpdate = now;
          _notificationService.updateDownloadProgress(
            task.trackId,
            task.track.title,
            progress,
          );
        }
      }

      // Delete any existing partial file before trying either strategy.
      if (await file.exists()) {
        await file.delete();
      }

      if (expectedTotal >= _parallelDownloadMinBytes &&
          _parallelDownloadPartCount >= kMinParallelDownloadPartCount) {
        final parallelBytes = await _downloadWithParallelRanges(
          trackId: task.trackId,
          streamUri: Uri.parse(streamUrl),
          outputFile: file,
          expectedBytes: expectedTotal,
          onProgress: (downloadedBytes) {
            totalDownloaded = downloadedBytes;
            reportProgress();
          },
        );
        if (parallelBytes != null) {
          downloadedWithParallel = true;
          totalDownloaded = parallelBytes;
          reportProgress(force: true);
          if (kDebugMode) {
            print(
              'DownloadService: Parallel download complete for ${task.trackId} ($totalDownloaded bytes)',
            );
          }
        }
      }

      if (!downloadedWithParallel) {
        if (_isTaskCancelled(task.trackId)) {
          throw const _DownloadCancelledException();
        }

        // Existing sequential download + continuation fallback.
        final sink = file.openWrite(mode: FileMode.writeOnly);
        try {
          _httpClient?.close();
          _httpClient = http.Client();
          var request = http.Request('GET', Uri.parse(streamUrl));
          request.headers['Accept-Encoding'] = 'identity';
          request.headers['Connection'] = 'keep-alive';

          var response = await _httpClient!.send(request);

          if (response.statusCode != 200 && response.statusCode != 206) {
            throw Exception('HTTP ${response.statusCode}');
          }

          final responseLength = response.contentLength ?? 0;
          if (responseLength > 0) {
            expectedTotal = responseLength;
          }
          if (kDebugMode) {
            print('DownloadService: Expected total size: $expectedTotal bytes');
          }

          await for (final chunk in response.stream) {
            if (_isTaskCancelled(task.trackId)) {
              throw const _DownloadCancelledException();
            }
            sink.add(chunk);
            totalDownloaded += chunk.length;
            reportProgress();
          }

          if (kDebugMode) {
            print(
              'DownloadService: Initial download got $totalDownloaded bytes',
            );
          }

          int rangeAttempts = 0;
          while (expectedTotal > 0 &&
              totalDownloaded < expectedTotal &&
              rangeAttempts < maxRangeAttempts) {
            if (_isTaskCancelled(task.trackId)) {
              throw const _DownloadCancelledException();
            }
            rangeAttempts++;
            final missing = expectedTotal - totalDownloaded;
            if (kDebugMode) {
              print(
                'DownloadService: Missing $missing bytes, attempting Range request (attempt $rangeAttempts)',
              );
            }

            await Future.delayed(const Duration(milliseconds: 500));
            if (_isTaskCancelled(task.trackId)) {
              throw const _DownloadCancelledException();
            }

            _httpClient?.close();
            _httpClient = http.Client();
            request = http.Request('GET', Uri.parse(streamUrl));
            request.headers['Accept-Encoding'] = 'identity';
            request.headers['Connection'] = 'keep-alive';
            request.headers['Range'] = 'bytes=$totalDownloaded-';

            try {
              response = await _httpClient!.send(request);

              if (response.statusCode != 200 && response.statusCode != 206) {
                if (kDebugMode) {
                  print(
                    'DownloadService: Range request failed with ${response.statusCode}',
                  );
                }
                break;
              }

              int chunkBytes = 0;
              await for (final chunk in response.stream) {
                if (_isTaskCancelled(task.trackId)) {
                  throw const _DownloadCancelledException();
                }
                sink.add(chunk);
                totalDownloaded += chunk.length;
                chunkBytes += chunk.length;
                reportProgress();
              }

              if (kDebugMode) {
                print(
                  'DownloadService: Range request got $chunkBytes more bytes, total: $totalDownloaded',
                );
              }

              if (chunkBytes == 0) {
                if (kDebugMode) {
                  print(
                    'DownloadService: Server returned empty response, assuming EOF',
                  );
                }
                break;
              }
            } catch (e) {
              if (e is _DownloadCancelledException) {
                rethrow;
              }
              if (kDebugMode) {
                print('DownloadService: Range request error: $e');
              }
              retryCount++;
              if (retryCount >= maxRetries) {
                break;
              }
            }
          }

          await sink.flush();
        } finally {
          await sink.close();
        }
      }

      // === RELAXED VALIDATION (OuterTune style) ===
      // Don't fail on small size mismatches - YouTube is unreliable
      // Trust the file header and minimum size instead

      final downloadedFile = File(filePath);
      if (!await downloadedFile.exists()) {
        throw Exception('Download failed: File was not created');
      }

      final actualFileSize = await downloadedFile.length();
      if (kDebugMode) {
        print(
          'DownloadService: Final file size: $actualFileSize bytes (expected: $expectedTotal)',
        );
      }

      // Check minimum file size (audio files should be at least 50KB)
      const minFileSize = 50 * 1024; // 50KB
      if (actualFileSize < minFileSize) {
        if (kDebugMode) {
          print(
            'DownloadService: File too small ($actualFileSize bytes), likely corrupted',
          );
        }
        await downloadedFile.delete();
        throw Exception(
          'Download corrupted: File too small (${(actualFileSize / 1024).toStringAsFixed(1)} KB)',
        );
      }

      // Check size difference - only fail if more than 5% missing
      if (expectedTotal > 0) {
        final missingBytes = expectedTotal - actualFileSize;
        final percentMissing = (missingBytes / expectedTotal) * 100;

        if (missingBytes > 0) {
          if (kDebugMode) {
            print(
              'DownloadService: Missing $missingBytes bytes (${percentMissing.toStringAsFixed(1)}%)',
            );
          }
        }

        // Accept up to 5% missing (OuterTune tolerates this)
        if (percentMissing > 5.0) {
          await downloadedFile.delete();
          throw Exception(
            'Download too incomplete: Missing ${percentMissing.toStringAsFixed(1)}% of file',
          );
        }
      }

      // Verify file header - this is the most reliable check
      final isValidAudio = await _verifyAudioFileHeader(
        downloadedFile,
        extension,
      );
      if (!isValidAudio) {
        if (kDebugMode) {
          print('DownloadService: File header verification failed');
        }
        await downloadedFile.delete();
        throw Exception('Download corrupted: Invalid audio file format');
      }

      if (kDebugMode) {
        print(
          'DownloadService: Download verified successfully - ${(actualFileSize / 1024 / 1024).toStringAsFixed(2)} MB',
        );
      }
      // === END VALIDATION ===

      // Save cover art next to audio file for offline-safe now playing artwork.
      await _downloadCoverArtForTrack(
        trackId: task.trackId,
        thumbnailUrl: task.track.thumbnailUrl,
        audioFilePath: filePath,
      );

      // Convert to M4A/AAC with embedded metadata for full music-player
      // support (title, artist, album and cover art).
      var finalPath = filePath;
      final convertedPath = await _convertToM4a(task, filePath);
      if (convertedPath != null) {
        finalPath = convertedPath;
      }

      // Make the file discoverable by other music apps on Android.
      await _notifyMediaScanner(finalPath);

      // Mark as completed
      final completedTask = task.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
        downloadedBytes: actualFileSize,
        totalBytes: actualFileSize,
        localPath: finalPath,
      );
      _updateTask(task.trackId, completedTask);
      _transientRetryAttempts.remove(task.trackId);

      ActivityLogService.success(
        'download',
        'Completed "${task.track.title}" (${_fmtBytes(actualFileSize)})',
      );

      // Persist to Hive for next app restart
      await _persistDownload(completedTask);

      // Trigger refresh of downloaded tracks provider
      _ref.read(downloadedTracksRefreshProvider.notifier).state++;

      // Show completion notification
      await _notificationService.showDownloadCompleted(
        task.trackId,
        task.track.title,
      );

      // Remove from queue
      final newQueue = List<String>.from(state.queue);
      newQueue.remove(task.trackId);
      state = state.copyWith(queue: newQueue, isDownloading: false);

      // Process next
      _processQueue();
    } on _DownloadCancelledException {
      ActivityLogService.w(
        'download',
        'Cancelled "${task.track.title}"',
      );
      if (kDebugMode) {
        print('DownloadService: Download cancelled: ${task.trackId}');
      }

      // Best-effort cleanup of partial output file.
      try {
        final dir = await _downloadsDir;
        final possibleExtensions = const <String>['.opus', '.m4a', '.webm'];
        for (final ext in possibleExtensions) {
          final candidate = File(
            '${dir.path}/${_downloadedFileName(task.track, ext)}',
          );
          if (await candidate.exists()) {
            await candidate.delete();
          }
          final coverCandidate = File(
            '${dir.path}/${_downloadedFileName(task.track, ext)}.cover.jpg',
          );
          if (await coverCandidate.exists()) {
            await coverCandidate.delete();
          }
        }
      } catch (_) {}

      await _notificationService.cancelNotification(task.trackId);
      _transientRetryAttempts.remove(task.trackId);

      final currentTask = state.tasks[task.trackId];
      if (currentTask != null &&
          currentTask.status != DownloadStatus.cancelled) {
        _updateTask(
          task.trackId,
          task.copyWith(status: DownloadStatus.cancelled, error: null),
        );
      }

      final newQueue = List<String>.from(state.queue);
      newQueue.remove(task.trackId);
      state = state.copyWith(queue: newQueue, isDownloading: false);
      _processQueue();
    } catch (e) {
      ActivityLogService.e(
        'download',
        'Failed "${task.track.title}": $e',
      );
      if (kDebugMode) {
        print('Download error: $e');
      }

      final isTransient = _isTransientDownloadError(e);
      if (isTransient) {
        final attempt = (_transientRetryAttempts[task.trackId] ?? 0) + 1;
        _transientRetryAttempts[task.trackId] = attempt;

        if (attempt <= kMaxTransientDownloadRetries) {
          final retryDelaySeconds = min(30, 2 + (attempt * 3));
          ActivityLogService.w(
            'download',
            '"${task.track.title}" transient error — retry $attempt/$kMaxTransientDownloadRetries in ${retryDelaySeconds}s',
          );
          if (kDebugMode) {
            print(
              'DownloadService: Transient error for $task.trackId, retry $attempt/$kMaxTransientDownloadRetries in $retryDelaySeconds s',
            );
          }

          _updateTask(
            task.trackId,
            task.copyWith(
              status: DownloadStatus.queued,
              error: 'Retrying ($attempt/$kMaxTransientDownloadRetries)...',
            ),
          );

          state = state.copyWith(isDownloading: false);
          Future<void>.delayed(Duration(seconds: retryDelaySeconds), () {
            final current = state.tasks[task.trackId];
            if (current == null || current.status == DownloadStatus.cancelled) {
              return;
            }
            _processQueue();
          });
          return;
        }
      }

      _transientRetryAttempts.remove(task.trackId);

      _updateTask(
        task.trackId,
        task.copyWith(status: DownloadStatus.failed, error: e.toString()),
      );

      // Show failure notification
      await _notificationService.showDownloadFailed(
        task.trackId,
        task.track.title,
        e.toString(),
      );

      // Remove from queue
      final newQueue = List<String>.from(state.queue);
      newQueue.remove(task.trackId);
      state = state.copyWith(queue: newQueue, isDownloading: false);

      // Process next
      _processQueue();
    }
  }

  void _updateTask(String trackId, DownloadTask task) {
    final newTasks = Map<String, DownloadTask>.from(state.tasks);
    newTasks[trackId] = task;
    state = state.copyWith(tasks: newTasks);
  }

  /// Verify audio file header matches expected format
  /// Returns true if the file appears to be a valid audio file
  Future<bool> _verifyAudioFileHeader(File file, String extension) async {
    try {
      final bytes = await file.openRead(0, 12).first;
      if (bytes.length < 4) return false;

      // Check for M4A/MP4 format (ftyp header)
      // M4A files start with: [size bytes] 'ftyp' [brand]
      if (extension == '.m4a') {
        // Look for 'ftyp' at byte 4 (after size field)
        if (bytes.length >= 8) {
          final ftyp = String.fromCharCodes(bytes.sublist(4, 8));
          if (ftyp == 'ftyp') {
            if (kDebugMode) {
              print('DownloadService: Valid M4A/MP4 header detected');
            }
            return true;
          }
        }
        // Also check if it starts with 'ftyp' directly (some files)
        final start = String.fromCharCodes(bytes.sublist(0, 4));
        if (start == 'ftyp') {
          if (kDebugMode) {
            print('DownloadService: Valid M4A/MP4 header detected (variant)');
          }
          return true;
        }
        if (kDebugMode) {
          print(
            'DownloadService: Invalid M4A header - got: ${bytes.sublist(0, 8)}',
          );
        }
        return false;
      }

      // Check for Opus/WebM format (EBML/WebM header)
      if (extension == '.opus' || extension == '.webm') {
        // WebM files start with EBML header: 0x1A 0x45 0xDF 0xA3
        if (bytes[0] == 0x1A &&
            bytes[1] == 0x45 &&
            bytes[2] == 0xDF &&
            bytes[3] == 0xA3) {
          if (kDebugMode) {
            print('DownloadService: Valid WebM/Opus header detected');
          }
          return true;
        }
        // Also check for OggS header (some Opus files)
        final start = String.fromCharCodes(bytes.sublist(0, 4));
        if (start == 'OggS') {
          if (kDebugMode) {
            print('DownloadService: Valid Ogg/Opus header detected');
          }
          return true;
        }
        if (kDebugMode) {
          print(
            'DownloadService: Invalid Opus/WebM header - got: ${bytes.sublist(0, 8)}',
          );
        }
        return false;
      }

      // Check for MP3 format (ID3 or sync bytes)
      if (extension == '.mp3') {
        // ID3 tag: starts with 'ID3'
        final id3 = String.fromCharCodes(bytes.sublist(0, 3));
        if (id3 == 'ID3') {
          if (kDebugMode) {
            print('DownloadService: Valid MP3 (ID3) header detected');
          }
          return true;
        }
        // MP3 sync: 0xFF 0xFB, 0xFF 0xFA, 0xFF 0xF3, 0xFF 0xF2
        if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
          if (kDebugMode) {
            print('DownloadService: Valid MP3 sync header detected');
          }
          return true;
        }
        return false;
      }

      // Unknown format - allow it (might be valid)
      if (kDebugMode) {
        print('DownloadService: Unknown format $extension, allowing');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('DownloadService: Header verification error: $e');
      }
      return false;
    }
  }

  /// Clear all completed downloads
  Future<void> clearCompleted() async {
    for (final task in state.completedTasks) {
      await removeDownload(task.trackId);
    }
  }

  /// Clear all failed downloads
  void clearFailed() {
    final failedIds = state.failedTasks.map((t) => t.trackId).toList();
    final newTasks = Map<String, DownloadTask>.from(state.tasks);
    for (final id in failedIds) {
      newTasks.remove(id);
    }
    state = state.copyWith(tasks: newTasks);
  }

  /// Remove old completed tasks from memory to prevent memory leaks
  /// Keeps the last hour of completed downloads in memory, older ones are only in Hive
  void _cleanupOldCompletedTasks() {
    final cutoffTime = DateTime.now().subtract(const Duration(hours: 1));
    final newTasks = Map<String, DownloadTask>.from(state.tasks);

    final toRemove = <String>[];
    for (final entry in newTasks.entries) {
      final task = entry.value;
      // Only remove completed tasks older than 1 hour
      if (task.status == DownloadStatus.completed &&
          task.startedAt.isBefore(cutoffTime)) {
        toRemove.add(entry.key);
      }
    }

    if (toRemove.isNotEmpty) {
      for (final id in toRemove) {
        newTasks.remove(id);
      }
      state = state.copyWith(tasks: newTasks);
      if (kDebugMode) {
        print(
          'DownloadService: Cleaned up ${toRemove.length} old completed tasks from memory',
        );
      }
    }
  }

  @override
  void dispose() {
    _cleanupTimer?.cancel();
    _currentDownload?.cancel();
    _httpClient?.close();
    super.dispose();
  }
}

/// Provider for YTPlayerUtils
final ytPlayerUtilsProvider = Provider<YTPlayerUtils>((ref) {
  return YTPlayerUtils.instance;
});

/// Provider for download manager
final downloadManagerProvider =
    StateNotifierProvider<DownloadManagerNotifier, DownloadManagerState>((ref) {
      final playerUtils = ref.watch(ytPlayerUtilsProvider);
      return DownloadManagerNotifier(playerUtils, ref);
    });

/// Provider to check if a specific track is downloaded
final isTrackDownloadedProvider = Provider.family<bool, String>((ref, trackId) {
  final downloadState = ref.watch(downloadManagerProvider);
  return downloadState.tasks[trackId]?.status == DownloadStatus.completed;
});

/// Sanitize a string for use as a filename
String _sanitizeFileName(String name) {
  // Remove or replace invalid filename characters
  return name
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Build the on-disk file name for a downloaded track: "Artist - Title.ext".
/// Falls back to the title alone (or "track") when the artist is missing.
String _downloadedFileName(Track track, String extension) {
  final title = _sanitizeFileName(track.title);
  final artist = _sanitizeFileName(track.artist);
  final artistPart = artist.isEmpty ? '' : '$artist - ';
  final name = '$artistPart$title'.trim();
  return '${name.isEmpty ? 'track' : name}$extension';
}

/// Provider for download progress of a specific track
final trackDownloadProgressProvider = Provider.family<double?, String>((
  ref,
  trackId,
) {
  final downloadState = ref.watch(downloadManagerProvider);
  final task = downloadState.tasks[trackId];
  if (task == null) return null;
  if (task.status == DownloadStatus.completed) return 1.0;
  if (task.status == DownloadStatus.downloading) return task.progress;
  return null;
});
