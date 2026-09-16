import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tuneload/core/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InzxAccentColor & ThemeProvider Tests', () {
    test('Default accent color is purple', () {
      final notifier = AccentColorNotifier();
      expect(notifier.state, InzxAccentColor.purple);
    });

    test('getAccentColor returns proper colors for presets', () {
      final purpleDark = getAccentColor(InzxAccentColor.purple, isDark: true);
      final purpleLight = getAccentColor(InzxAccentColor.purple, isDark: false);
      expect(purpleDark, const Color(0xFF9F7AEA));
      expect(purpleLight, const Color(0xFF6B46C1));

      final redDark = getAccentColor(InzxAccentColor.red, isDark: true);
      expect(redDark, const Color(0xFFE53935));
    });

    test('getAccentColor handles custom color', () {
      const myCustomColor = Color(0xFF123456);
      final resolved = getAccentColor(
        InzxAccentColor.custom,
        isDark: true,
        customColor: myCustomColor,
      );
      expect(resolved, myCustomColor);
    });

    test('CustomAccentColorNotifier updates color properly', () async {
      final customNotifier = CustomAccentColorNotifier();
      const newColor = Color(0xFF00FFCC);
      await customNotifier.setCustomColor(newColor);
      expect(customNotifier.state, newColor);
    });

    test('AccentColorNotifier updates preset properly', () async {
      final notifier = AccentColorNotifier();
      await notifier.setAccentColor(InzxAccentColor.ocean);
      expect(notifier.state, InzxAccentColor.ocean);

      await notifier.setAccentColor(InzxAccentColor.custom);
      expect(notifier.state, InzxAccentColor.custom);
    });
  });
}
