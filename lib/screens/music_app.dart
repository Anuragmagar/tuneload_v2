import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../core/l10n/app_localizations_x.dart';
import '../models/models.dart';
import '../../../core/design_system/design_system.dart';
import '../providers/providers.dart';
import '../providers/bookmarks_and_stats_provider.dart';
import 'tabs/home_tab.dart';
import 'tabs/songs_tab.dart';
import 'tabs/library_tab.dart';
import 'widgets/mini_player.dart';
import 'widgets/now_playing_screen.dart';
import 'widgets/about_tuneload_dialog.dart';
import 'jams_screen.dart';
import 'ytmusic_settings_screen.dart';

/// Standalone Music App with its own navigation
class MusicApp extends ConsumerStatefulWidget {
  const MusicApp({super.key});

  @override
  ConsumerState<MusicApp> createState() => _MusicAppState();
}

class _MusicAppState extends ConsumerState<MusicApp>
    with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _currentIndex = 0;
  String _appVersion = '';
  String? _lastTrackedId;
  late AnimationController _animationController;

  final List<Widget> _tabs = const [
    MusicHomeTab(),
    MusicSongsTab(),
    MusicLibraryTab(),
    YTMusicSettingsScreen(embeddedInTab: true),
  ];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = info.version);
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onTabSelected(int index) {
    if (index != _currentIndex) {
      setState(() => _currentIndex = index);
      _animationController.forward(from: 0);
    }
  }

  /// TuneLoad-style navigation drawer (hamburger menu)
  Widget _buildTuneLoadDrawer() {
    const brandRed = Color(0xFFF15656);
    const wine = Color(0xFF832F47);

    Widget item({
      required IconData icon,
      required String title,
      String? subtitle,
      required VoidCallback onTap,
      bool selected = false,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: selected
                    ? brandRed.withValues(alpha: 0.12)
                    : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? brandRed.withValues(alpha: 0.28)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: (selected ? brandRed : Colors.white24)
                          .withValues(alpha: selected ? 0.22 : 0.08),
                    ),
                    child: Icon(
                      icon,
                      size: 21,
                      color: selected ? brandRed : Colors.white70,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: selected ? Colors.white : Colors.white70,
                            fontSize: 15,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: const TextStyle(
                              color: Color(0xFF9A9BA3),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (selected)
                    Container(
                      width: 3,
                      height: 24,
                      decoration: BoxDecoration(
                        color: brandRed,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget sectionLabel(String label) => Padding(
          padding: const EdgeInsets.fromLTRB(30, 18, 20, 6),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
            ),
          ),
        );

    return Drawer(
      width: 304,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(26)),
      ),
      backgroundColor: Colors.transparent,
      child: ClipRRect(
        borderRadius:
            const BorderRadius.horizontal(right: Radius.circular(26)),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF191A22), Color(0xFF0B0C11)],
            ),
          ),
          child: Stack(
            children: [
              // Soft wine glow behind the brand header
              Positioned(
                top: -80,
                right: -60,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        wine.withValues(alpha: 0.45),
                        wine.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Brand header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                      child: Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [wine, brandRed],
                              ),
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: brandRed.withValues(alpha: 0.35),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.music_note_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: 'Tune',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 20,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      TextSpan(
                                        text: 'Load',
                                        style: TextStyle(
                                          color: brandRed,
                                          fontSize: 20,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _appVersion.isEmpty
                                      ? 'In development'
                                      : 'v$_appVersion',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 11,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Divider(
                        height: 16,
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    // Menu items
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 12),
                        children: [
                          sectionLabel('MENU'),
                          item(
                            icon: Icons.home_rounded,
                            title: 'Home',
                            selected: _currentIndex == 0,
                            onTap: () {
                              Navigator.of(context).pop();
                              setState(() => _currentIndex = 0);
                            },
                          ),
                          item(
                            icon: Icons.groups_rounded,
                            title: 'Jams',
                            subtitle: 'Real-time listening sessions',
                            onTap: () {
                              Navigator.of(context).pop();
                              JamsScreen.open(context);
                            },
                          ),
                          sectionLabel('MORE'),
                          item(
                            icon: Icons.person_rounded,
                            title: 'Connect YouTube Music',
                            subtitle: 'Account & library',
                            onTap: () {
                              Navigator.of(context).pop();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) =>
                                      const YTMusicSettingsScreen(),
                                ),
                              );
                            },
                          ),
                          item(
                            icon: Icons.info_outline_rounded,
                            title: 'About TuneLoad',
                            onTap: () {
                              Navigator.of(context).pop();
                              AboutTuneLoadDialog.show(
                                context,
                                version: _appVersion,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    // Footer
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: const [
                          Text(
                            'Made with ❤️ by Anurag',
                            style: TextStyle(
                              color: Colors.white24,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep stats and recent history in sync with real playback transitions.
    ref.listen<Track?>(currentTrackProvider, (previous, next) {
      if (next == null) return;
      if (_lastTrackedId == next.id) return;
      _lastTrackedId = next.id;

      ref.read(recentlyPlayedProvider.notifier).addTrack(next);
      ref.read(playStatisticsProvider.notifier).recordPlay(next);
    });

    final playbackState = ref.watch(playbackStateProvider);
    final hasCurrentTrack =
        playbackState.whenOrNull(data: (s) => s.currentTrack != null) ?? false;
    final l10n = context.l10n;

    // TuneLoad skin: always a dark base underneath the wine-red gradient
    final Color backgroundColor = InzxColors.darkBackground;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (_currentIndex != 0) {
            setState(() => _currentIndex = 0);
          } else {
            SystemNavigator.pop();
          }
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        resizeToAvoidBottomInset: false,
        backgroundColor: backgroundColor,
        drawer: _buildTuneLoadDrawer(),
body: Stack(
          children: [
            // TuneLoad wine gradient background (copied from the primary app)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    stops: const [0.6, 1.0],
                    colors: const [Color(0xFF101115), Color(0xFF832F47)],
                  ),
                ),
              ),
            ),
            // Backdrop overlay like the primary app (blur + black layer)
            Positioned.fill(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.30)),
                ),
              ),
            ),
            // Top bar + main content (inside SafeArea like the primary app)
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: _TuneLoadTopBar(
                      onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                    ),
                  ),
                  Expanded(
                    child: IndexedStack(index: _currentIndex, children: _tabs),
                  ),
                  // Mini player sits above the navigation bar
                  if (hasCurrentTrack)
                    MusicMiniPlayer(
                      onTap: () => NowPlayingScreen.show(context),
                    ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          backgroundColor: InzxColors.darkBottomNavigation,
          onDestinationSelected: _onTabSelected,
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.home_rounded),
              label: l10n.home,
            ),
            NavigationDestination(
              icon: const Icon(Icons.music_note_rounded),
              label: l10n.songs,
            ),
            NavigationDestination(
              icon: const Icon(Icons.library_music_rounded),
              label: l10n.library,
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_rounded),
              label: l10n.settings,
            ),
          ],
        ),
      ),
    );
  }
}

/// TuneLoad-style top bar (hamburger menu + centered wordmark)
/// Copied from the primary app's topbar.dart.
class _TuneLoadTopBar extends StatelessWidget {
  final VoidCallback onMenu;

  const _TuneLoadTopBar({required this.onMenu});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // App bar / hamburger button
        GestureDetector(
          onTap: onMenu,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: const Color.fromRGBO(139, 139, 139, 0),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(5),
              color: const Color.fromRGBO(217, 217, 217, 0.25),
            ),
            child: const Padding(
              padding: EdgeInsets.all(5.0),
              child: Icon(Icons.menu_rounded, size: 18, color: Colors.white),
            ),
          ),
        ),
        const Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "Tune ",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                "Load",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color.fromRGBO(241, 86, 86, 1),
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
