import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bask/theme/mono_theme.dart';
import 'package:bask/theme/theme_palette.dart';

/// Contrast ratio, so the accent assertions state a legibility floor rather
/// than pinning hex values a designer may want to retune.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('ThemePalette', () {
    test('neutral contributes nothing, so the mono theme is untouched', () {
      for (final dark in [true, false]) {
        for (final oled in [true, false]) {
          expect(ThemePalette.neutral.colorsFor(dark: dark, oled: oled), isNull);
        }
      }
    });

    test('neutral builds the same theme the app shipped with', () {
      // The guarantee existing installs rely on: adding palettes moved no
      // colour for anyone who has not picked one.
      for (final (dark, oled) in [(true, false), (false, false), (true, true)]) {
        final withDefault = monoTheme(
          oled
              ? MonoPalette.oled
              : dark
              ? MonoPalette.dark
              : MonoPalette.light,
        );
        final explicit = monoTheme(ThemePalette.neutral.monoFor(dark: dark, oled: oled));
        expect(explicit.colorScheme, withDefault.colorScheme);
        expect(explicit.scaffoldBackgroundColor, withDefault.scaffoldBackgroundColor);
      }
    });

    test('every coloured palette tints the surfaces and carries an accent', () {
      for (final palette in ThemePalette.values.where((p) => p != ThemePalette.neutral)) {
        final colors = palette.colorsFor(dark: true, oled: false)!;
        final reason = palette.name;

        // Tinted, not grey: a grey has all three channels equal.
        final bg = colors.bg;
        expect(
          (bg.r == bg.g && bg.g == bg.b),
          isFalse,
          reason: '$reason background should carry a hue, not be neutral grey',
        );

        // Dark enough to still be a dark theme.
        expect(colors.bg.computeLuminance(), lessThan(0.05), reason: '$reason background should stay dark');
        expect(colors.surface.computeLuminance(), lessThan(0.08), reason: '$reason surface should stay dark');

        // The accent has to be readable both against the surfaces it sits on
        // and under the foreground it is given.
        expect(contrast(colors.accent, colors.bg), greaterThan(3.0), reason: '$reason accent on its background');
        expect(contrast(colors.accent, colors.onAccent), greaterThan(4.5), reason: '$reason foreground on its accent');
      }
    });

    test('OLED keeps pure black and tints the cards instead', () {
      for (final palette in ThemePalette.values.where((p) => p != ThemePalette.neutral)) {
        final colors = palette.colorsFor(dark: true, oled: true)!;
        expect(colors.bg, const Color(0xFF000000), reason: '${palette.name} must not spend the OLED black');
        expect(colors.surface, isNot(const Color(0xFF000000)), reason: '${palette.name} should tint its cards');
      }
    });

    test('light mode stays light and still carries a legible accent', () {
      for (final palette in ThemePalette.values.where((p) => p != ThemePalette.neutral)) {
        final colors = palette.colorsFor(dark: false, oled: false)!;
        expect(colors.bg.computeLuminance(), greaterThan(0.8), reason: '${palette.name} light background');
        expect(
          contrast(colors.accent, colors.surface),
          greaterThan(3.0),
          reason: '${palette.name} light accent on its surface',
        );
        expect(contrast(colors.accent, colors.onAccent), greaterThan(4.5), reason: '${palette.name} light foreground');
      }
    });

    test('a palette reaches the accent roles of the built theme', () {
      final neutral = monoTheme(ThemePalette.neutral.monoFor(dark: true, oled: false));
      for (final palette in ThemePalette.values.where((p) => p != ThemePalette.neutral)) {
        // Against the palette the theme is actually built from: ember,
        // glacier and paper carry upstream's tuned colours for the brightness
        // they were drawn for rather than the hue recipe.
        final mono = palette.monoFor(dark: true, oled: false);
        final theme = monoTheme(mono);
        expect(theme.colorScheme.primary, mono.accent, reason: palette.name);
        expect(theme.colorScheme.onPrimary, mono.onAccent, reason: palette.name);
        expect(theme.scaffoldBackgroundColor, mono.bg, reason: palette.name);
        expect(theme.colorScheme.primary, isNot(neutral.colorScheme.primary), reason: palette.name);
      }
    });
  });
}
