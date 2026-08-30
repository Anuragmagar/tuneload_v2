import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../design_system/colors.dart';

/// Theme mode options for the app
enum InzxThemeMode { system, light, dark }

/// Available accent color options
enum InzxAccentColor {
  red, // AMOLED red - default
  purple, // Purple/Violet/Lilac #6B46C1
  sage, // Sage green
  lavender, // Soft lavender
  peach, // Warm peach
  ocean, // Ocean blue
  rose, // Soft rose
  amber, // Warm amber
  mint, // Fresh mint
  coral, // Soft coral
  custom, // Custom user chosen color
}

/// Get the Color value for an accent color option
Color getAccentColor(InzxAccentColor accent, {bool isDark = false, Color? customColor}) {
  switch (accent) {
    case InzxAccentColor.purple:
      return isDark ? const Color(0xFF9F7AEA) : const Color(0xFF6B46C1);
    case InzxAccentColor.red:
      return isDark ? const Color(0xFFE53935) : const Color(0xFFD32F2F);
    case InzxAccentColor.sage:
      return isDark ? const Color(0xFF8FD4B6) : InzxColors.accent;
    case InzxAccentColor.lavender:
      return isDark ? const Color(0xFFB8B4DE) : InzxColors.accentSecondary;
    case InzxAccentColor.peach:
      return isDark ? const Color(0xFFF8C4B0) : InzxColors.accentTertiary;
    case InzxAccentColor.ocean:
      return isDark ? const Color(0xFF7BC4E8) : const Color(0xFF7BC4E8);
    case InzxAccentColor.rose:
      return isDark ? const Color(0xFFE4B5B5) : const Color(0xFFE4B5B5);
    case InzxAccentColor.amber:
      return isDark ? const Color(0xFFF8D08D) : const Color(0xFFF8D08D);
    case InzxAccentColor.mint:
      return isDark ? const Color(0xFF8FE4C8) : const Color(0xFF7DD4B8);
    case InzxAccentColor.coral:
      return isDark ? const Color(0xFFF8C4B0) : const Color(0xFFF8C4B0);
    case InzxAccentColor.custom:
      return customColor ?? (isDark ? const Color(0xFF9F7AEA) : const Color(0xFF6B46C1));
  }
}

/// Get the display name for an accent color
String getAccentColorName(InzxAccentColor accent) {
  switch (accent) {
    case InzxAccentColor.purple:
      return 'Purple';
    case InzxAccentColor.red:
      return 'Red';
    case InzxAccentColor.sage:
      return 'Sage Green';
    case InzxAccentColor.lavender:
      return 'Lavender';
    case InzxAccentColor.peach:
      return 'Peach';
    case InzxAccentColor.ocean:
      return 'Ocean Blue';
    case InzxAccentColor.rose:
      return 'Rose';
    case InzxAccentColor.amber:
      return 'Amber';
    case InzxAccentColor.mint:
      return 'Mint';
    case InzxAccentColor.coral:
      return 'Coral';
    case InzxAccentColor.custom:
      return 'Custom';
  }
}

/// Provider for the custom accent color
final customAccentColorProvider =
    StateNotifierProvider<CustomAccentColorNotifier, Color>((ref) {
      return CustomAccentColorNotifier();
    });

/// Notifier to manage custom accent color
class CustomAccentColorNotifier extends StateNotifier<Color> {
  static const String customAccentPrefKey = 'inzx_custom_accent_color_int';

  CustomAccentColorNotifier() : super(const Color(0xFF9F7AEA)) {
    _loadCustomColor();
  }

  Future<void> _loadCustomColor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final colorInt = prefs.getInt(customAccentPrefKey);
      if (colorInt != null) {
        state = Color(colorInt);
      }
    } catch (_) {}
  }

  Future<void> setCustomColor(Color color) async {
    state = color;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(customAccentPrefKey, color.toARGB32());
    } catch (_) {}
  }
}

/// Provider for the current accent color
final accentColorProvider =
    StateNotifierProvider<AccentColorNotifier, InzxAccentColor>((ref) {
      return AccentColorNotifier();
    });

/// Notifier to manage accent color state
class AccentColorNotifier extends StateNotifier<InzxAccentColor> {
  static const String accentColorPrefKey = 'inzx_accent_color_enum';

  AccentColorNotifier() : super(InzxAccentColor.red) {
    _loadAccentColor();
  }

  Future<void> _loadAccentColor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final index = prefs.getInt(accentColorPrefKey);
      if (index != null && index >= 0 && index < InzxAccentColor.values.length) {
        state = InzxAccentColor.values[_migrateAccentIndex(index)];
      }
    } catch (_) {}
  }

  /// Remap persisted indices from before red and purple were swapped in the
  /// enum (previously purple=0, red=1; now red=0, purple=1).
  int _migrateAccentIndex(int index) {
    if (index == 0) return 1; // old purple -> new purple
    if (index == 1) return 0; // old red -> new red
    return index;
  }

  Future<void> setAccentColor(InzxAccentColor color) async {
    state = color;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(accentColorPrefKey, color.index);
    } catch (_) {}
  }
}

/// Provider for the current theme mode
final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, InzxThemeMode>((ref) {
      return ThemeModeNotifier();
    });

/// Notifier to manage theme mode state
class ThemeModeNotifier extends StateNotifier<InzxThemeMode> {
  static const String themeModePrefKey = 'inzx_theme_mode';
  static const String _legacyThemeModePrefKey = 'inzx_theme_mode';

  ThemeModeNotifier() : super(InzxThemeMode.dark) {
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      int? index = prefs.getInt(themeModePrefKey);
      if (index == null) {
        index = prefs.getInt(_legacyThemeModePrefKey);
        if (index != null) {
          await prefs.setInt(themeModePrefKey, index);
          await prefs.remove(_legacyThemeModePrefKey);
        }
      }
      if (index == null || index < 0 || index >= InzxThemeMode.values.length) {
        return;
      }
      state = InzxThemeMode.values[index];
    } catch (_) {
      // Keep default theme if preference loading fails.
    }
  }

  Future<void> _saveThemeMode(InzxThemeMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(themeModePrefKey, mode.index);
    } catch (_) {
      // Non-fatal: theme still updates in memory.
    }
  }

  void setThemeMode(InzxThemeMode mode) {
    state = mode;
    _saveThemeMode(mode);
  }

  void toggleTheme() {
    switch (state) {
      case InzxThemeMode.system:
        state = InzxThemeMode.light;
        break;
      case InzxThemeMode.light:
        state = InzxThemeMode.dark;
        break;
      case InzxThemeMode.dark:
        state = InzxThemeMode.system;
        break;
    }
  }
}

/// Convert InzxThemeMode to Flutter's ThemeMode
ThemeMode toFlutterThemeMode(InzxThemeMode mode) {
  switch (mode) {
    case InzxThemeMode.system:
      return ThemeMode.system;
    case InzxThemeMode.light:
      return ThemeMode.light;
    case InzxThemeMode.dark:
      return ThemeMode.dark;
  }
}

/// Provider for the user's display name (for personalization)
final userNameProvider = StateNotifierProvider<UserNameNotifier, String>((ref) {
  return UserNameNotifier();
});

/// Notifier to manage user name state
class UserNameNotifier extends StateNotifier<String> {
  UserNameNotifier() : super('Music Lover');

  void setName(String name) {
    state = name.trim().isEmpty ? 'Music Lover' : name.trim();
  }
}
