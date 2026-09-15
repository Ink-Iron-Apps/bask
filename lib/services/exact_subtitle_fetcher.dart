import '../media/media_item.dart';
import '../models/plex/plex_subtitle_search_result.dart';
import '../utils/app_logger.dart';
import 'plex_client.dart';
import 'settings_service.dart';

/// Fetches a subtitle timed to this exact file, for a video that has none.
///
/// Only a hash match qualifies. OpenSubtitles' moviehash says the subtitle was
/// authored against a file with this file's hash, so it cannot drift; a merely
/// high-scoring subtitle for another release can be minutes out by the end of
/// a film, which is worse than showing nothing. When there is no hash match
/// this does nothing and leaves the choice to the user, who can still search
/// by hand and judge the results.
class ExactSubtitleFetcher {
  ExactSubtitleFetcher._();

  /// Keys already attempted this session, so a title with no exact match is
  /// asked about once rather than on every replay.
  static final Set<String> _attempted = <String>{};

  static void resetForTesting() => _attempted.clear();

  /// Returns true when a subtitle was requested from the server.
  ///
  /// The server downloads asynchronously and the new stream appears on a later
  /// metadata read, so this deliberately does not wait for it or try to select
  /// it: the next playback of the item picks it up through the normal
  /// track-selection path.
  static Future<bool> fetchIfMissing({
    required MediaItem metadata,
    required PlexClient client,
    required bool hasSubtitleTracks,
    required String languageCode,
    SettingsService? settingsOverride,
  }) async {
    if (hasSubtitleTracks) return false;

    final settings = settingsOverride ?? SettingsService.instanceOrNull;
    if (settings == null || !settings.read(SettingsService.autoFetchExactSubtitles)) return false;

    final key = metadata.globalKey;
    if (!_attempted.add(key)) return false;

    try {
      final results = await client.searchSubtitles(metadata.id, language: languageCode);
      final exact = results.where((result) => result.perfectMatch).firstOrNull;
      if (exact == null) {
        appLogger.d('No exact-match subtitle for ${metadata.displayTitle}');
        return false;
      }

      final requested = await client.downloadSubtitle(
        metadata.id,
        key: exact.key,
        codec: exact.codec ?? 'srt',
        language: exact.languageCode ?? languageCode,
        hearingImpaired: exact.hearingImpaired,
        forced: exact.forced,
        providerTitle: exact.providerTitle ?? '',
      );
      if (requested) {
        appLogger.i('Requested an exact-match subtitle for ${metadata.displayTitle}');
      }
      return requested;
    } catch (e, stackTrace) {
      // Best-effort by design: a video with no subtitles is the state we were
      // already in, so a failure here costs nothing and must not touch
      // playback.
      appLogger.d('Exact-match subtitle fetch failed', error: e, stackTrace: stackTrace);
      return false;
    }
  }

  /// Visible for the search sheet's own ranking, which applies the same rule.
  static PlexSubtitleSearchResult? exactMatchIn(List<PlexSubtitleSearchResult> results) =>
      results.where((result) => result.perfectMatch).firstOrNull;
}
