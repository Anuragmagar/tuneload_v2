import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'audio_player_service.dart' as player;

/// Syncs playback metadata to the native Android home-screen widget.
class WidgetSyncService {
  static const MethodChannel _channel = MethodChannel('inzx/widget');

  static String? _lastFingerprint;
  static String? _lastProgressFingerprint;
  static String? _lastArtworkTrackId;

  static Future<void> syncPlaybackState(
    player.PlaybackState state, {
    String? statusLabel,
  }) async {
    final track = state.currentTrack;
    final hasTrack = track != null;
    final effectiveDuration =
        state.duration ?? track?.duration ?? Duration.zero;

    final payload = <String, dynamic>{
      'trackId': track?.id,
      'title': track?.title ?? 'Not playing',
      'artist': track?.artist ?? 'Open TuneLoad to start music',
      'isPlaying': state.isPlaying,
      'hasTrack': hasTrack,
      'positionMs': state.position.inMilliseconds,
      'durationMs': effectiveDuration.inMilliseconds,
    };
    payload['statusLabel'] = statusLabel?.trim() ?? '';

    final fingerprint = _fingerprintFrom(
      track,
      state.isPlaying,
      hasTrack,
      statusLabel,
    );
    if (_lastFingerprint == fingerprint) return;
    _lastFingerprint = fingerprint;

    if (track?.id != _lastArtworkTrackId) {
      _lastArtworkTrackId = track?.id;
      final thumbnail = track?.bestThumbnail;
      if (thumbnail != null && thumbnail.isNotEmpty) {
        final artBytes = await _downloadArtworkBytes(thumbnail);
        if (artBytes != null && artBytes.isNotEmpty) {
          payload['artBytes'] = artBytes;
        }
      }
    }

    try {
      await _channel.invokeMethod('syncPlaybackState', payload);
    } catch (_) {
      // Widget sync is best-effort and should never block playback controls.
    }
  }

  static Future<void> syncProgress({
    required Track? track,
    required bool isPlaying,
    required bool hasTrack,
    required Duration position,
    required Duration? duration,
  }) async {
    if (!hasTrack) return;

    // Widget progress updates are throttled to 1-second buckets.
    final secondBucket = position.inSeconds;
    final durationMs =
        (duration ?? track?.duration ?? Duration.zero).inMilliseconds;
    final progressFingerprint =
        '${track?.id ?? ''}|$secondBucket|$durationMs|$isPlaying';
    if (_lastProgressFingerprint == progressFingerprint) return;
    _lastProgressFingerprint = progressFingerprint;

    final payload = <String, dynamic>{
      'positionMs': position.inMilliseconds,
      'durationMs': durationMs,
      'hasTrack': hasTrack,
      'isPlaying': isPlaying,
    };

    try {
      await _channel.invokeMethod('syncPlaybackState', payload);
    } catch (_) {
      // Widget sync is best-effort and should never block playback controls.
    }
  }

  static String _fingerprintFrom(
    Track? track,
    bool isPlaying,
    bool hasTrack,
    String? statusLabel,
  ) {
    final id = track?.id ?? '';
    final title = track?.title ?? '';
    final artist = track?.artist ?? '';
    final status = statusLabel ?? '';
    return '$id|$title|$artist|$isPlaying|$hasTrack|$status';
  }

  static Future<Uint8List?> _downloadArtworkBytes(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return null;
      final response = await http
          .get(uri, headers: {'User-Agent': 'TuneLoadWidget/1.0'})
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      if (response.bodyBytes.isEmpty) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }
}
