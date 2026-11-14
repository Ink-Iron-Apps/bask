import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A colour identity applied on top of the light/dark/OLED mode.
///
/// [neutral] is the monochrome look the app shipped with: it contributes no
/// colours at all, so `monoTheme` keeps using its own greys and every accent
/// role stays mapped to the text colour. Every other value tints the surfaces
/// and gives the accent roles a hue, while leaving the mode in charge of
/// brightness — "dark + plum" is still a dark theme.
enum ThemePalette { neutral, navy, indigo, teal, plum, forest, amber, crimson, slate }

/// The colours a palette contributes to one brightness of the theme.
@immutable
class PaletteColors {
  /// Scaffold background.
  final Color bg;

  /// Cards and raised surfaces.
  final Color surface;

  /// Buttons, focus, progress and selected states — `colorScheme.primary`.
  final Color accent;

  /// Legible foreground on [accent], picked by contrast rather than by a
  /// lightness threshold.
  final Color onAccent;

  const PaletteColors({required this.bg, required this.surface, required this.accent, required this.onAccent});
}

/// Ink used as the dark option when choosing a foreground for an accent.
/// Matches the neutral dark background so an accent-filled button reads as a
/// hole punched in the surface rather than as a third colour.
const _accentInk = Color(0xFF0E0F12);

/// WCAG relative-luminance contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Whichever of white or [_accentInk] is more legible on [accent].
///
/// A fixed lightness threshold gets this wrong in the middle of the range:
/// amber at 0.42 luminance is over most thresholds yet carries only 2.2:1
/// against white and 8.4:1 against ink.
Color _onAccentFor(Color accent) =>
    _contrast(accent, Colors.white) >= _contrast(accent, _accentInk) ? Colors.white : _accentInk;

Color _hsl(double hue, double saturation, double lightness) =>
    HSLColor.fromAHSL(1, hue, saturation.clamp(0.0, 1.0), lightness.clamp(0.0, 1.0)).toColor();

/// Contrast an accent must clear against the surface it is drawn on. 3:1 is
/// the WCAG floor for large text and UI components; the extra 0.2 is headroom
/// so a later tweak to a hue does not silently land on the line.
const _minAccentContrast = 3.2;

/// The accent for light mode: the hue, darkened until it clears
/// [_minAccentContrast] against white.
///
/// Equal lightness is not equal brightness across hues — cyan, amber and
/// emerald at the lightness that makes indigo readable are still pale smears
/// on a white card. Searching for the contrast instead of tabulating a
/// lightness per hue keeps that property true when a hue is retuned.
Color _lightAccent(double hue, double saturation) {
  for (var lightness = 0.40; lightness > 0.18; lightness -= 0.02) {
    final candidate = _hsl(hue, saturation, lightness);
    if (_contrast(candidate, Colors.white) >= _minAccentContrast) return candidate;
  }
  return _hsl(hue, saturation, 0.18);
}

extension ThemePaletteColors on ThemePalette {
  /// The hue the surfaces and the accent share, and how far the *surfaces* are
  /// pushed toward it. Null for [ThemePalette.neutral], which has no hue.
  ///
  /// Surface saturation stays well under the accent's: at the lightness a dark
  /// background lives at, every point of saturation is visible, and a fully
  /// saturated background fights the artwork the app exists to show.
  ({double hue, double saturation})? get _tint => switch (this) {
    ThemePalette.neutral => null,
    // True navy: bluer and less violet than [indigo], and the most saturated
    // of the surface tints, because blue at this lightness reads as grey
    // sooner than any other hue.
    ThemePalette.navy => (hue: 217, saturation: 0.60),
    ThemePalette.indigo => (hue: 231, saturation: 0.45),
    ThemePalette.teal => (hue: 187, saturation: 0.45),
    ThemePalette.plum => (hue: 287, saturation: 0.42),
    ThemePalette.forest => (hue: 152, saturation: 0.45),
    ThemePalette.amber => (hue: 33, saturation: 0.42),
    ThemePalette.crimson => (hue: 349, saturation: 0.44),
    // Barely tinted on purpose: the option for wanting a hint of colour
    // rather than a colour.
    ThemePalette.slate => (hue: 213, saturation: 0.22),
  };

  /// Saturation and lightness of the accent on a dark theme. Lightness is
  /// per-hue because equal-lightness hues are not equally bright — green at
  /// 0.70 glares where blue at 0.70 reads as mid-tone.
  ({double saturation, double lightness})? get _accentTone => switch (this) {
    ThemePalette.neutral => null,
    ThemePalette.navy => (saturation: 0.90, lightness: 0.62),
    ThemePalette.indigo => (saturation: 0.88, lightness: 0.70),
    ThemePalette.teal => (saturation: 0.85, lightness: 0.56),
    ThemePalette.plum => (saturation: 0.80, lightness: 0.70),
    ThemePalette.forest => (saturation: 0.75, lightness: 0.52),
    ThemePalette.amber => (saturation: 0.92, lightness: 0.56),
    ThemePalette.crimson => (saturation: 0.82, lightness: 0.64),
    ThemePalette.slate => (saturation: 0.45, lightness: 0.66),
  };

  /// This palette's contribution for one brightness, or null when it has
  /// nothing to say and the caller should keep its own greys.
  ///
  /// [oled] keeps the pure-black background the OLED mode exists for — the
  /// tint lands on the cards above it instead, which is where it is visible
  /// without costing the black.
  PaletteColors? colorsFor({required bool dark, required bool oled}) {
    final tint = _tint;
    final tone = _accentTone;
    if (tint == null || tone == null) return null;

    if (dark || oled) {
      final accent = _hsl(tint.hue, tone.saturation, tone.lightness);
      return PaletteColors(
        bg: oled ? const Color(0xFF000000) : _hsl(tint.hue, tint.saturation, 0.075),
        surface: _hsl(tint.hue, tint.saturation * 0.95, oled ? 0.05 : 0.11),
        accent: accent,
        onAccent: _onAccentFor(accent),
      );
    }

    // Light mode takes the tint at a fraction of the dark strength: a light
    // theme's background is mostly white, where the saturation that reads as
    // "deep navy" at 0.075 lightness reads as a wash.
    final accent = _lightAccent(tint.hue, math.min(tone.saturation * 0.95, 1.0));
    return PaletteColors(
      bg: _hsl(tint.hue, tint.saturation * 0.45, 0.965),
      surface: const Color(0xFFFFFFFF),
      accent: accent,
      onAccent: _onAccentFor(accent),
    );
  }
}
