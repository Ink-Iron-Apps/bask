import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// One bundled subtitle font: its asset, the file name libass sees, and the
/// asset's byte length, which is what decides whether an extracted copy is
/// current. The cache directory outlives app updates, so "the file exists"
/// says nothing about which build wrote it; the length does, at the cost of
/// one stat. Every [SubtitleFontLoader.fonts] length is pinned to the real
/// asset by `test/mpv/font_loader_test.dart`, so regenerating a font without
/// updating its length fails the test instead of shipping the stale copy.
class SubtitleFont {
  const SubtitleFont({required this.asset, required this.fileName, required this.length});

  final String asset;
  final String fileName;
  final int length;
}

/// Extracts font files from Flutter assets to the cache directory for
/// comprehensive Unicode coverage (including CJK and Hangul characters) for
/// libass subtitles.
///
/// GoNotoCurrent (the primary font) covers every common script except Korean,
/// and the Android libmpv build has no fontconfig/system-font fallback, so
/// libass can only find glyphs in this directory. libass only considers fonts
/// whose name-table family equals the requested `sub-font` ([fontName]) and
/// then picks, per codepoint, the candidate that has the glyph. The Hangul
/// companion next to the primary therefore carries the primary's family name
/// (not its upstream one) and exactly the codepoints the primary lacks: the
/// 11172 Hangul syllables. It is generated from GoNotoKurrent-Regular
/// (satbyy/go-noto-universal v7.0) by
/// `scripts/codegen/generate_hangul_subtitle_font.py`, which also verifies
/// those invariants (`--check`).
class SubtitleFontLoader {
  static const String _fontName = 'Go Noto Current-Regular';

  /// Font files extracted to the subtitle fonts directory, in extraction order:
  /// the primary, then its Hangul-syllable companion (see class docs).
  static const List<SubtitleFont> fonts = [
    SubtitleFont(
      asset: 'assets/go-noto-current-regular.ttf',
      fileName: 'go-noto-current-regular.ttf',
      length: 14700060,
    ),
    SubtitleFont(asset: 'assets/go-noto-kurrent-hangul.ttf', fileName: 'go-noto-kurrent-hangul.ttf', length: 1976696),
  ];

  /// Suffix of a copy still being written; a leftover one is stale by definition.
  static const String _partialSuffix = '.partial';

  /// Forget the resolved directory so the next [loadSubtitleFont] re-runs the
  /// extraction.
  @visibleForTesting
  static void resetForTesting() {
    _cachedFontDir = null;
  }

  /// In-memory cache of the resolved font directory. The filesystem work
  /// (temp dir lookup, length checks, asset extraction) is idempotent per
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
      if (resolved != null && fonts.every((f) => File(path.join(resolved, f.fileName)).existsSync())) {
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

      await fontDir.create(recursive: true);

      // libass loads every file in the directory, so anything that is not a
      // current copy of a bundled font has to go: an earlier build's version
      // of the same file name, a copy truncated by a crash, an interrupted
      // write. Length is the currency check; a file of the right name and
      // length is a copy of the asset this build ships.
      final expected = {for (final font in fonts) font.fileName: font.length};
      final current = <String>{};
      await for (final entry in fontDir.list(followLinks: false)) {
        final name = path.basename(entry.path);
        if (entry is File && expected[name] == await entry.length()) {
          current.add(name);
        } else {
          await entry.delete(recursive: true);
        }
      }

      for (final font in fonts) {
        if (current.contains(font.fileName)) continue;
        final data = await rootBundle.load(font.asset);
        final partial = File(path.join(fontDir.path, font.fileName + _partialSuffix));
        await partial.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
        await partial.rename(path.join(fontDir.path, font.fileName));
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
