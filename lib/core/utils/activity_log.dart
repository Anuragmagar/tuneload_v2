import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Severity/kind of a logged activity.
enum ActivityLogLevel {
  /// General info (downloads, playback, lyrics, system)
  info,

  /// A discrete step in a pipeline
  step,

  /// An operation attempt (retries, fallbacks)
  attempt,

  /// Successful operations
  success,

  /// Warned conditions
  warning,

  /// Failed operations
  error,

  /// Network/resolver activity
  network,

  /// Metadata writes/queries
  metadata,

  /// Lyrics resolution
  lyrics,

  /// Download pipeline activity
  download,

  /// Verbose debug detail (only surfaced when verbose logging is enabled)
  debug,
}

/// Short display codes for well-known log tags (compact terminal look).
const Map<String, String> _tagCodes = {
  'download': 'DL',
  'convert': 'CONV',
  'tag': 'TAG',
  'lyrics': 'LYRIC',
  'playback': 'AUDIO',
  'app': 'APP',
  'platform': 'PLAT',
};

/// A single, timestamped line shown in the in-app activity terminal.
class ActivityLogEntry {
  final DateTime time;
  final ActivityLogLevel level;
  final String tag;
  final String message;

  ActivityLogEntry({
    required this.message,
    this.level = ActivityLogLevel.info,
    this.tag = '',
    DateTime? time,
  }) : time = time ?? DateTime.now();

  /// Compact clock timestamp, e.g. `14:03:27`.
  String get formattedTime {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// Bracket label shown before the message, e.g. `[DL]` or `[WARN]`.
  String get displayTag {
    if (tag.isNotEmpty) {
      return '[${_tagCodes[tag.toLowerCase()] ?? tag.toUpperCase()}]';
    }
    switch (level) {
      case ActivityLogLevel.success:
        return '[OK]';
      case ActivityLogLevel.warning:
        return '[WARN]';
      case ActivityLogLevel.error:
        return '[ERR]';
      case ActivityLogLevel.attempt:
        return '[TRY]';
      case ActivityLogLevel.step:
        return '[STEP]';
      case ActivityLogLevel.network:
        return '[NET]';
      case ActivityLogLevel.metadata:
        return '[META]';
      case ActivityLogLevel.lyrics:
        return '[LYRIC]';
      case ActivityLogLevel.download:
        return '[DL]';
      case ActivityLogLevel.debug:
        return '[DBG]';
      case ActivityLogLevel.info:
        return '[INFO]';
    }
  }

  @override
  String toString() => '$formattedTime $displayTag $message';
}

/// Global in-app activity log bus.
///
/// Every logged activity is kept in a capped in-memory buffer and also
/// surfaced through a [ValueNotifier] (for widgets like the terminal panel)
/// and a broadcast stream (for live auto-scroll). Services log through the
/// static helpers below (or through [Log] in `logger.dart`, which forwards
/// here), so anything interesting shows up in the terminal with a timestamp,
/// a tag and a severity color regardless of source.
class ActivityLogService {
  ActivityLogService._();

  static final ActivityLogService instance = ActivityLogService._();

  /// Maximum number of entries kept in memory.
  static const int maxEntries = 800;

  /// Global verbose toggle (mirrors [Log.verbose]).
  static bool verbose = true;

  final List<ActivityLogEntry> _entries = <ActivityLogEntry>[];
  final List<ActivityLogEntry> _unmodifiable = <ActivityLogEntry>[];
  final _controller = StreamController<ActivityLogEntry>.broadcast();

  /// Latest snapshot for `ValueListenableBuilder`-driven widgets.
  final ValueNotifier<List<ActivityLogEntry>> logsNotifier =
      ValueNotifier<List<ActivityLogEntry>>(const <ActivityLogEntry>[]);

  /// Never throws / never fails: logging is best-effort at all times.
  void _add(ActivityLogLevel level, String? tag, String message) {
    if (!kDebugMode && level == ActivityLogLevel.debug) return;
    try {
      final entry = ActivityLogEntry(
        time: DateTime.now(),
        level: level,
        tag: tag ?? 'app',
        message: message,
      );
      _entries.add(entry);
      if (_entries.length > maxEntries) {
        _entries.removeRange(0, _entries.length - maxEntries);
      }
      _unmodifiable
        ..clear()
        ..addAll(_entries);
      logsNotifier.value = UnmodifiableListView(_unmodifiable);

      if (_controller.hasListener) {
        _controller.add(entry);
      }
    } catch (_) {}
  }

  /// Logs an info line.
  static void i(String tag, String message) =>
      ActivityLogService.instance._add(ActivityLogLevel.info, tag, message);

  /// Logs a success line.
  static void success(String tag, String message) =>
      ActivityLogService.instance
          ._add(ActivityLogLevel.success, tag, message);

  /// Logs a warning line.
  static void w(String tag, String message) =>
      ActivityLogService.instance._add(ActivityLogLevel.warning, tag, message);

  /// Logs an error line.
  static void e(String tag, String message) =>
      ActivityLogService.instance._add(ActivityLogLevel.error, tag, message);

  /// Logs a verbose debug line (omitted when [verbose] is off).
  static void d(String tag, String message) {
    if (!verbose) return;
    ActivityLogService.instance._add(ActivityLogLevel.debug, tag, message);
  }

  /// Stream of newly added entries (live updates for the terminal).
  Stream<ActivityLogEntry> get stream => _controller.stream;

  /// Stream of newly added entries (alias, panel uses this for auto-scroll).
  Stream<ActivityLogEntry> get logStream => _controller.stream;

  /// All buffered entries, oldest first.
  UnmodifiableListView<ActivityLogEntry> get entries =>
      UnmodifiableListView(_unmodifiable);

  /// All buffered entries, oldest first (snapshot for the terminal panel).
  List<ActivityLogEntry> get logs => logsNotifier.value;

  /// Number of buffered entries.
  int get length => _entries.length;

  /// Removes all buffered entries.
  void clear() {
    _entries.clear();
    _unmodifiable.clear();
    logsNotifier.value = const <ActivityLogEntry>[];
  }
}