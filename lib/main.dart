import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:ui' show PlatformDispatcher;
import 'core/design_system/design_system.dart';
import 'core/l10n/app_localizations_x.dart';
import 'core/providers/locale_provider.dart';
import 'core/providers/theme_provider.dart';
import 'core/services/cache/hive_service.dart';
import 'core/utils/activity_log.dart';
import 'l10n/generated/app_localizations.dart';
import 'services/audio_handler.dart';
import 'services/audio_player_service.dart';
import 'services/github_release_update_service.dart';
import 'services/jams/jams_background_service_native.dart';
import 'services/notification_service.dart';
import 'services/shorebird_update_service.dart';
import 'services/supabase_config.dart';
import 'providers/providers.dart';
import 'providers/repository_providers.dart';
import 'screens/music_app.dart';
import 'services/deep_link_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'screens/widgets/whats_new_dialog.dart';

InzxAudioHandler? audioHandler;
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>();
VoidCallback? requestAppRestart;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  ActivityLogService.i('app', 'TuneLoad starting...');

  // Initialize environment variables
  try {
    await dotenv.load(fileName: ".env");
    ActivityLogService.success('app', 'Dotenv initialized');
    debugPrint('✅ Dotenv initialized successfully');
  } catch (e) {
    ActivityLogService.w('app', 'Dotenv initialization failed: $e');
    debugPrint('⚠️ Dotenv initialization failed: $e');
  }

  // Initialize Hive for caching
  try {
    await HiveService.init();
    ActivityLogService.success('app', 'Hive cache initialized');
    debugPrint('✅ Hive initialized successfully');
  } catch (e) {
    ActivityLogService.w('app', 'Hive initialization failed: $e');
    debugPrint('⚠️ Hive initialization failed: $e');
  }

  // Initialize Supabase for Jams feature
  try {
    await SupabaseConfig.initialize();
    ActivityLogService.success('app', 'Supabase initialized');
  } catch (e) {
    ActivityLogService.w('app', 'Supabase initialization failed: $e');
    debugPrint('⚠️ Supabase initialization failed: $e');
  }

  // Initialize audio service for background playback
  try {
    audioHandler = await initAudioService();
  } catch (e) {
    ActivityLogService.w('app', 'Audio service init failed: $e');
    debugPrint('Audio service initialization failed: $e');
  }

  // Initialize notification service for download progress
  try {
    await DownloadNotificationService.instance.initialize();
    ActivityLogService.success('app', 'Notification service initialized');
    debugPrint('✅ Notification service initialized successfully');
  } catch (e) {
    ActivityLogService.w('app', 'Notification service init failed: $e');
    debugPrint('⚠️ Notification service initialization failed: $e');
  }
  // Initialize native bridge for Jams foreground service (Android)
  try {
    await JamsBackgroundService.instance.initialize();
  } catch (e) {
    ActivityLogService.w('app', 'Jams background service init failed: $e');
    debugPrint('Jams background service initialization failed: $e');
  }

  // Wire up the in-app activity log terminal: playback events, global errors.
  _wireActivityLogging();

  // Set preferred orientations
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(RestartableApp(audioHandler: audioHandler));
}

/// Subscribe to playback + global error streams so everything interesting is
/// visible in the in-app Activity Log terminal. Runs once at startup and
/// lives for the whole app lifetime.
void _wireActivityLogging() {
  // Uncaught Flutter framework errors.
  final oldOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    ActivityLogService.e(
      'flutter',
      '${details.exception.runtimeType}: ${details.exception}',
    );
    oldOnError?.call(details);
  };

  // Uncaught errors from zones/platform.
  PlatformDispatcher.instance.onError = (error, stack) {
    ActivityLogService.e('platform', '$error\n$stack');
    return false;
  };

  // Playback transitions and errors.
  final audio = AudioPlayerService.instance;
  String? lastTrackId;
  audio.stateStream.listen((state) {
    final track = state.currentTrack;
    if (track != null && track.id != lastTrackId) {
      lastTrackId = track.id;
      ActivityLogService.i('playback', 'Now playing "${track.title}"');
    }
    if (state.error != null && state.error!.isNotEmpty) {
      ActivityLogService.e(
        'playback',
        '${track?.title ?? 'Player'}: ${state.error}',
      );
    }
  });
  audio.trackCompleteStream.listen((track) {
    ActivityLogService.i('playback', 'Finished "${track.title}"');
  });
}

class RestartableApp extends StatefulWidget {
  final InzxAudioHandler? audioHandler;

  const RestartableApp({super.key, required this.audioHandler});

  static void restart(BuildContext context) {
    final state = context.findAncestorStateOfType<_RestartableAppState>();
    state?.restart();
  }

  @override
  State<RestartableApp> createState() => _RestartableAppState();
}

class _RestartableAppState extends State<RestartableApp> {
  Key _providerScopeKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    requestAppRestart = restart;
  }

  @override
  void dispose() {
    if (identical(requestAppRestart, restart)) {
      requestAppRestart = null;
    }
    super.dispose();
  }

  void restart() {
    setState(() {
      _providerScopeKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      key: _providerScopeKey,
      overrides: [
        if (widget.audioHandler != null)
          audioHandlerProvider.overrideWithValue(widget.audioHandler),
      ],
      child: const InzxApp(),
    );
  }
}

/// The root widget of the TuneLoad music app
class InzxApp extends ConsumerStatefulWidget {
  const InzxApp({super.key});

  @override
  ConsumerState<InzxApp> createState() => _InzxAppState();
}

class _InzxAppState extends ConsumerState<InzxApp> {
  @override
  void initState() {
    super.initState();

    // Warm cache on startup (background task)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cacheWarmer = ref.read(cacheWarmingServiceProvider);
      cacheWarmer.warmCache(preTrendingMusic: true, prelikedSongs: true);
      _runUpdateChecks();
      DeepLinkHandler.instance.initialize(context, ref);
    });
  }

  Future<void> _runUpdateChecks() async {
    _checkFirstLaunchChangelog();

    final didPatchUpdate = await ShorebirdUpdateService.instance
        .checkForUpdates();
    if (!mounted) return;

    if (didPatchUpdate) {
      _showPatchUpdateBanner();
    }
  }

  Future<void> _checkFirstLaunchChangelog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final lastSeenVersion = prefs.getString('last_seen_changelog_version');

      if (lastSeenVersion != currentVersion) {
        final releaseInfo = await GithubReleaseUpdateService.instance.fetchLatestReleaseInfo();
        if (!mounted) return;
        final navContext = rootNavigatorKey.currentContext ?? context;
        await WhatsNewDialog.show(navContext, releaseInfo: releaseInfo, currentVersion: currentVersion);
        await prefs.setString('last_seen_changelog_version', currentVersion);
      }
    } catch (e) {
      debugPrint('Error showing changelog dialog: $e');
    }
  }

  void _showPatchUpdateBanner() {
    final messenger = rootScaffoldMessengerKey.currentState;
    if (messenger == null) return;
    final l10n = context.l10n;
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(
      MaterialBanner(
        content: Text(l10n.updateDownloadedBanner),
        actions: [
          TextButton(
            onPressed: () {
              // Close the app so the update applies on next launch.
              // Android can pop the system back stack; iOS has no public API,
              // so hard-exit is used there (necessary for Shorebird OTA
              // patches which only take effect on a fresh launch).
              if (defaultTargetPlatform == TargetPlatform.android) {
                SystemNavigator.pop();
              } else {
                exit(0);
              }
            },
            child: Text(l10n.restart),
          ),
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: Text(l10n.dismiss),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(appLocaleProvider);

    // Get accent color
    final accentColorEnum = ref.watch(accentColorProvider);
    final customAccent = ref.watch(customAccentColorProvider);
    final lightAccent = getAccentColor(accentColorEnum, isDark: false, customColor: customAccent);
    final darkAccent = getAccentColor(accentColorEnum, isDark: true, customColor: customAccent);

    ThemeData lightTheme = InzxTheme.lightWithAccent(lightAccent);
    ThemeData darkTheme = InzxTheme.darkWithAccent(darkAccent);

    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      locale: locale,
      supportedLocales: supportedAppLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: lightTheme,
      darkTheme: darkTheme,
      // TuneLoad skin is dark-only; ignore light/system mode selection.
      themeMode: ThemeMode.dark,
      home: const MusicApp(),
      builder: (context, child) {
        // Update system UI
        final brightness = Theme.of(context).brightness;
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: brightness == Brightness.light
                ? Brightness.dark
                : Brightness.light,
            statusBarBrightness: brightness,
            systemNavigationBarColor: brightness == Brightness.light
                ? InzxColors.background
                : InzxColors.darkBottomNavigation,
            systemNavigationBarIconBrightness: brightness == Brightness.light
                ? Brightness.dark
                : Brightness.light,
          ),
        );

        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(
              MediaQuery.of(context).textScaler.scale(1.0).clamp(0.8, 1.2),
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
