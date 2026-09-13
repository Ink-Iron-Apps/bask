import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// Extracts font files from Flutter assets to the cache directory for
/// comprehensive Unicode coverage (including CJK and Hangul characters) for
/// libass subtitles.
///
/// GoNotoCurrent (the primary font) covers every common script except Korean,
/// and the Android libmpv build has no fontconfig/system-font fallback, so
/// libass can only find glyphs in this directory. The Hangul subset next to
/// it provides the missing syllables: generated from GoNotoKurrent-Regular
/// (satbyy/go-noto-universal v7.0) via fontTools.subset, keeping Hangul
/// Syllables, Jamo, compat Jamo, and common Hangul punctuation.
class SubtitleFontLoader {
  static const String _fontAssetPath = 'assets/go-noto-current-regular.ttf';
  static const String _fontName = 'Go Noto Current-Regular';

  /// Hangul-only subset of Go Noto Kurrent-Regular (see class docs).
  static const String _hangulFontAssetPath = 'assets/go-noto-kurrent-hangul.ttf';

  /// Font files extracted to the subtitle fonts directory, in extraction order.
  static const List<(String, String)> _fonts = [
    (_fontAssetPath, 'go-noto-current-regular.ttf'),
    (_hangulFontAssetPath, 'go-noto-kurrent-hangul.ttf'),
  ];

  /// In-memory cache of the resolved font directory. The filesystem work
  /// (temp dir lookup, existence checks, asset extraction) is idempotent per
  /// process — caching the result skips ~20ms on every subsequent Player
  /// instantiation.
  static Future<String?>? _cachedFontDir;

  static Future<String?> loadSubtitleFont() {
    return _cachedFontDir = _loadSubtitleFontOnce(previous: _cachedFontDir);
  }

  /// Re-extracts anything missing rather than trusting the cached path.
  ///
  /// These files live in the cache directory, which Android reclaims on its own
  /// when storage runs low — and a TV's data partition is small enough for that
  /// to happen in ordinary use. The Android libmpv build has no fontconfig, so
  /// an emptied directory leaves libass with no glyphs at all and subtitles
  /// silently stop rendering until the app is restarted. Checking costs two
  /// stat calls per playback; the extraction itself still only runs when a file
  /// is actually gone.
  static Future<String?> _loadSubtitleFontOnce({Future<String?>? previous}) async {
    try {
      final resolved = await previous;
      if (resolved != null && _fonts.every((f) => File(path.join(resolved, f.$2)).existsSync())) {
        return resolved;
      }
      // Application support, not the cache directory: Android reclaims the
      // cache on its own when storage runs low — a TV's data partition is small
      // enough for that to happen in ordinary use — and the Android libmpv
      // build has no fontconfig, so an emptied directory leaves libass with no
      // glyphs and subtitles silently stop rendering. Support survives that.
      final baseDir = await getApplicationSupportDirectory();
      final fontDir = Directory(path.join(baseDir.path, 'subtitle_fonts'));

      // Anything left in the old cache location is dead weight now.
      unawaited(_removeLegacyCacheCopy());

      if (!await fontDir.exists()) {
        await fontDir.create(recursive: true);
      }

      for (final (assetPath, fileName) in _fonts) {
        final fontFile = File(path.join(fontDir.path, fileName));
        if (await fontFile.exists()) continue;
        final fontData = await rootBundle.load(assetPath);
        await fontFile.writeAsBytes(fontData.buffer.asUint8List());
      }

      return fontDir.path;
    } catch (e, st) {
      appLogger.w('Failed to load subtitle font', error: e, stackTrace: st);
      return null;
    }
  }

  /// Deletes the pre-move copy under the cache directory.
  ///
  /// Best-effort: it is a few megabytes of fonts that nothing reads any more,
  /// and on the devices where this matters the space itself is the point.
  static Future<void> _removeLegacyCacheCopy() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final legacy = Directory(path.join(cacheDir.path, 'subtitle_fonts'));
      if (legacy.existsSync()) await legacy.delete(recursive: true);
    } catch (e) {
      appLogger.d('Could not remove the legacy subtitle font cache', error: e);
    }
  }

  static String get fontName => _fontName;
}
