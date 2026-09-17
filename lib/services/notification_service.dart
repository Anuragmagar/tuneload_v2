import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:ui' as ui;
import '../core/l10n/app_localizations_x.dart';
import '../core/providers/locale_provider.dart';
import '../l10n/generated/app_localizations.dart';

/// Service to handle download progress notifications
class DownloadNotificationService {
  static final DownloadNotificationService _instance =
      DownloadNotificationService._internal();
  static DownloadNotificationService get instance => _instance;
  factory DownloadNotificationService() => _instance;
  DownloadNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  AppLocalizations? _cachedL10n;
  String? _cachedLocaleKey;

  // Notification channel for downloads
  static const String _channelId = 'download_channel';

  // Base notification ID (we'll add track hash to make unique IDs)
  static const int _baseNotificationId = 1000;

  /// Initialize the notification service
  ///
  /// Never throws: a failing platform channel (e.g. R8-stripped generic
  /// signatures on release builds) must not break the download flow, so any
  /// error here is logged and swallowed.
  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      final l10n = await _resolveL10n();

      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const initSettings = InitializationSettings(android: androidSettings);

      await _notifications.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      // Create the notification channel for Android
      final androidPlugin = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      if (androidPlugin != null) {
        await androidPlugin.createNotificationChannel(
          AndroidNotificationChannel(
            _channelId,
            l10n.downloads,
            description: l10n.downloadNotificationsChannelDescription,
            importance: Importance.low, // Low so it doesn't make sound
            showBadge: false,
          ),
        );

        try {
          // Clear any stale ongoing "downloading…" notifications left behind
          // by a process that was killed mid-download. Downloads never survive
          // a process death, so a lingering progress notification can only be
          // a leak. Wrapped in its own try so this cannot fail initialization.
          await _notifications.cancelAll();
        } catch (e) {
          debugPrint('NotificationService: cancelAll failed (non-fatal): $e');
        }

        // Request notification permission for Android 13+
        if (Platform.isAndroid) {
          await androidPlugin.requestNotificationsPermission();
        }
      }
    } catch (e) {
      debugPrint('NotificationService: initialize failed (non-fatal): $e');
    }

    _isInitialized = true;
  }

  void _onNotificationTapped(NotificationResponse response) {
    // Handle notification tap - could open download manager
    debugPrint('Notification tapped: ${response.payload}');
  }

  /// Get unique notification ID for a track
  int _getNotificationId(String trackId) {
    return _baseNotificationId + trackId.hashCode.abs() % 10000;
  }

  /// Show download started notification
  Future<void> showDownloadStarted(String trackId, String trackTitle) async {
    if (!_isInitialized) await initialize();
    final l10n = await _resolveL10n();

    final notificationId = _getNotificationId(trackId);

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      l10n.downloads,
      channelDescription: l10n.downloadNotificationsChannelDescription,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: 0,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      icon: '@mipmap/ic_launcher',
      subText: l10n.downloading,
    );

    try {
      await _notifications.show(
        notificationId,
        trackTitle,
        l10n.downloadStartingNotification,
        NotificationDetails(android: androidDetails),
        payload: trackId,
      );
    } catch (e) {
      debugPrint('NotificationService: showDownloadStarted failed '
          '(non-fatal): $e');
    }
  }

  /// Update download progress notification
  Future<void> updateDownloadProgress(
    String trackId,
    String trackTitle,
    double progress,
  ) async {
    if (!_isInitialized) await initialize();
    final l10n = await _resolveL10n();

    final notificationId = _getNotificationId(trackId);
    final progressPercent = (progress * 100).toInt();

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      l10n.downloads,
      channelDescription: l10n.downloadNotificationsChannelDescription,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: progressPercent,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      icon: '@mipmap/ic_launcher',
      subText: '$progressPercent%',
    );

    try {
      await _notifications.show(
        notificationId,
        trackTitle,
        l10n.downloadingProgress(progressPercent),
        NotificationDetails(android: androidDetails),
        payload: trackId,
      );
    } catch (e) {
      debugPrint('NotificationService: updateDownloadProgress failed '
          '(non-fatal): $e');
    }
  }

  /// Show an indeterminate progress notification while the downloaded file is
  /// being converted/tagged (FFmpeg) — there is no meaningful byte progress.
  Future<void> showDownloadConverting(
    String trackId,
    String trackTitle,
  ) async {
    if (!_isInitialized) await initialize();
    final l10n = await _resolveL10n();

    final notificationId = _getNotificationId(trackId);

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      l10n.downloads,
      channelDescription: l10n.downloadNotificationsChannelDescription,
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: 100,
      progress: 0,
      indeterminate: true,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      icon: '@mipmap/ic_launcher',
      subText: l10n.converting,
    );

    try {
      await _notifications.show(
        notificationId,
        trackTitle,
        l10n.converting,
        NotificationDetails(android: androidDetails),
        payload: trackId,
      );
    } catch (e) {
      debugPrint('NotificationService: showDownloadConverting failed '
          '(non-fatal): $e');
    }
  }

  /// Show download completed notification
  Future<void> showDownloadCompleted(String trackId, String trackTitle) async {
    if (!_isInitialized) await initialize();
    final l10n = await _resolveL10n();

    final notificationId = _getNotificationId(trackId);

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      l10n.downloads,
      channelDescription: l10n.downloadNotificationsChannelDescription,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      icon: '@mipmap/ic_launcher',
    );

    try {
      await _notifications.show(
        notificationId,
        trackTitle,
        l10n.downloadCompleteNotification,
        NotificationDetails(android: androidDetails),
        payload: trackId,
      );

      // Auto-dismiss after 3 seconds
      Future.delayed(const Duration(seconds: 3), () {
        cancelNotification(trackId);
      });
    } catch (e) {
      debugPrint('NotificationService: showDownloadCompleted failed '
          '(non-fatal): $e');
    }
  }

  /// Show download failed notification
  Future<void> showDownloadFailed(
    String trackId,
    String trackTitle,
    String error,
  ) async {
    if (!_isInitialized) await initialize();
    final l10n = await _resolveL10n();

    final notificationId = _getNotificationId(trackId);

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      l10n.downloads,
      channelDescription: l10n.downloadNotificationsChannelDescription,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
      icon: '@mipmap/ic_launcher',
    );

    try {
      await _notifications.show(
        notificationId,
        trackTitle,
        localizeDownloadError(l10n, error),
        NotificationDetails(android: androidDetails),
        payload: trackId,
      );
    } catch (e) {
      debugPrint('NotificationService: showDownloadFailed failed '
          '(non-fatal): $e');
    }
  }

  Future<AppLocalizations> _resolveL10n() async {
    final prefs = await SharedPreferences.getInstance();
    final storedCode = prefs.getString(AppLocaleNotifier.localePrefKey);
    final systemLocale = ui.PlatformDispatcher.instance.locale;
    final cacheKey =
        '${storedCode ?? 'system'}|${appLocaleStorageKey(resolveEffectiveAppLocale(systemLocale: systemLocale))}';

    if (_cachedL10n != null && _cachedLocaleKey == cacheKey) {
      return _cachedL10n!;
    }

    final locale = resolveEffectiveAppLocale(
      storedCode: storedCode,
      systemLocale: systemLocale,
    );

    final l10n = lookupAppLocalizations(locale);
    _cachedL10n = l10n;
    _cachedLocaleKey = cacheKey;
    return l10n;
  }

  /// Cancel notification for a track
  Future<void> cancelNotification(String trackId) async {
    try {
      final notificationId = _getNotificationId(trackId);
      await _notifications.cancel(notificationId);
    } catch (e) {
      debugPrint('NotificationService: cancelNotification failed '
          '(non-fatal): $e');
    }
  }

  /// Cancel all download notifications
  Future<void> cancelAllNotifications() async {
    try {
      await _notifications.cancelAll();
    } catch (e) {
      debugPrint('NotificationService: cancelAllNotifications failed '
          '(non-fatal): $e');
    }
  }
}
