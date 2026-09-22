import '../media/media_item.dart';
import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart';
import 'scoped_player_prefs.dart';
import 'settings_service.dart';
import 'subtitle_rate_detector.dart';
import 'subtitle_timing.dart';

/// Corrects a subtitle file timed for another frame rate, without being asked.
///
/// The Subtitle Rate control has existed for a while and works — but it asks
/// the viewer to notice the drift, work out which conversion it is, and set it
/// per file. The drift is measurable: a subtitle authored against a 25 fps
/// transfer of a 23.976 fps film covers 4.27% less time than the film does,
/// and that shows up in the file's own timestamps.
///
/// Only external text subtitles can be measured this way — the file has to be
/// readable. Embedded tracks are left alone.
class SubtitleRateGuard {
  SubtitleRateGuard._();

  /// Keys already measured this session, so a replay does not re-fetch.
  static final Set<String> _checked = <String>{};

  static void resetForTesting() => _checked.clear();

  /// Measure [subtitleUri] against the video and store a correction if needed.
  ///
  /// Returns the speed written, or null when nothing was changed. Never
  /// throws: a subtitle that cannot be fetched or parsed is the state we were
  /// already in.
  static Future<double?> applyIfMistimed({
    required MediaItem? metadata,
    required String subtitleUri,
    required Duration videoDuration,
    SettingsService? settingsOverride,
    Future<String?> Function(String uri)? fetchOverride,
  }) async {
    final settings = settingsOverride ?? SettingsService.instanceOrNull;
    if (settings == null) return null;

    final mode = settings.read(SettingsService.subtitleRateCorrection);
    if (mode == SubtitleRateCorrection.off) return null;

    // A rate the viewer (or an earlier pass) already chose for this item wins:
    // being overruled by the app is worse than the drift it is fixing.
    final existing = ScopedPlayerPrefs.resolve(ScopedPlayerPrefs.subtitleSpeed, metadata);
    if (!sameSubtitleSpeed(existing, 1.0)) return null;

    final key = '${metadata?.globalKey ?? 'unknown'}|$subtitleUri';
    if (!_checked.add(key)) return null;

    try {
      final content = await (fetchOverride ?? _fetchSubtitle)(subtitleUri);
      if (content == null) return null;

      final span = parseSubtitleSpan(content);
      if (span == null) return null;

      final suggestion = detectSubtitleRate(
        span: span,
        videoDurationMs: videoDuration.inMilliseconds,
        allowAmbiguous: mode == SubtitleRateCorrection.always,
      );
      if (suggestion == null) return null;

      final speed = clampSubtitleSpeed(
        suggestion.speed,
        min: ScopedPlayerPrefs.minimumSubtitleSpeed,
        max: ScopedPlayerPrefs.maximumSubtitleSpeed,
      );
      await ScopedPlayerPrefs.write(ScopedPlayerPrefs.subtitleSpeed, metadata, speed);
      appLogger.i(
        'Subtitle rate: correcting to ${speed.toStringAsFixed(5)} '
        '(span ${suggestion.measuredRatio.toStringAsFixed(4)} of the video, '
        '${suggestion.certain ? 'past the end' : 'a known conversion'})',
      );
      return speed;
    } catch (e, stackTrace) {
      appLogger.d('Subtitle rate: could not measure $subtitleUri', error: e, stackTrace: stackTrace);
      return null;
    }
  }

  /// Subtitle files are small; anything large enough to matter is not one.
  static const int _maxBytes = 4 * 1024 * 1024;

  static Future<String?> _fetchSubtitle(String uri) async {
    final response = await httpClient.get(uri);
    final data = response.data;
    if (data is! String || data.length > _maxBytes) return null;
    return data;
  }
}
