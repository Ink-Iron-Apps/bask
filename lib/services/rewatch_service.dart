import '../media/episode_collection.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../utils/app_logger.dart';

/// One show being rewatched, and the episode that comes next in it.
class RewatchEntry {
  const RewatchEntry({required this.showKey, required this.lastWatched, required this.next});

  /// Grandparent (show) id the rewatch belongs to.
  final String showKey;

  /// The most recently played episode of that show.
  final MediaItem lastWatched;

  /// The episode to offer, in the shared watch order.
  final MediaItem next;
}

/// Builds the "continue rewatching" list a server will not offer on its own.
///
/// Plex's On Deck — and so Continue Watching — only ever holds the next
/// *unwatched* episode, so a show you have finished disappears from it
/// entirely. Rewatching it means either unmarking episodes, which destroys
/// the record of having seen them, or remembering where you were. Neither is
/// something to ask of someone watching television.
///
/// Everything here is derived from state the server already keeps per user —
/// `lastViewedAt` and `viewCount` per episode — so it is the same answer on
/// every device signed in as that user, with nothing stored locally and
/// nothing to sync.
class RewatchService {
  RewatchService._();

  /// How long a rewatch stays on the rail without being touched.
  ///
  /// Long enough to survive a fortnight's break, short enough that a series
  /// finished months ago does not sit on the home screen forever. A rewatch
  /// that ends because the show ended is dropped the moment there is no next
  /// episode, whatever this says.
  static const Duration defaultFreshness = Duration(days: 30);

  /// The most recently played episode per show, newest first.
  ///
  /// [episodes] is any set of episodes carrying `lastViewedAt`; the caller
  /// supplies them from a `lastViewedAt`-sorted library query.
  static List<MediaItem> mostRecentPerShow(
    Iterable<MediaItem> episodes, {
    DateTime? now,
    Duration freshness = defaultFreshness,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(freshness).millisecondsSinceEpoch ~/ 1000;
    final newestByShow = <String, MediaItem>{};

    for (final episode in episodes) {
      if (!episode.isEpisode) continue;
      final showKey = episode.grandparentId;
      final viewedAt = episode.lastViewedAt;
      // Never played, or played too long ago to still be a rewatch in
      // progress. An episode with no show to group under cannot resolve a
      // next episode either.
      if (showKey == null || viewedAt == null || viewedAt <= 0 || viewedAt < cutoff) continue;

      final held = newestByShow[showKey];
      if (held == null || (held.lastViewedAt ?? 0) < viewedAt) newestByShow[showKey] = episode;
    }

    final ordered = newestByShow.values.toList()..sort((a, b) => (b.lastViewedAt ?? 0).compareTo(a.lastViewedAt ?? 0));
    return ordered;
  }

  /// The episode following [lastWatched] in the shared watch order.
  ///
  /// Returns null at the end of a show: the rewatch is finished, and offering
  /// its first episode again would restart it without being asked.
  static MediaItem? nextAfter(MediaItem lastWatched, List<MediaItem> showEpisodes) {
    if (showEpisodes.isEmpty) return null;
    final ordered = List<MediaItem>.of(showEpisodes);
    sortEpisodesByWatchOrder(ordered);
    final index = ordered.indexWhere((episode) => episode.id == lastWatched.id);
    if (index == -1) return null;
    return nextEpisodeSkippingSameFile(ordered, index);
  }

  /// Assemble the rail.
  ///
  /// [alreadyOffered] holds the keys the server's own Continue Watching
  /// already covers — a show mid-season is its job, and showing it twice
  /// would be the app arguing with the server about what is next.
  /// [episodesForShow] fetches a show's episodes; it is called at most
  /// [maxEntries] times, since each is a server round trip.
  static Future<List<RewatchEntry>> build({
    required Iterable<MediaItem> recentlyWatched,
    required Future<List<MediaItem>> Function(MediaItem lastWatched) episodesForShow,
    Set<String> alreadyOffered = const {},
    int maxEntries = 8,
    DateTime? now,
    Duration freshness = defaultFreshness,
  }) async {
    final candidates = mostRecentPerShow(recentlyWatched, now: now, freshness: freshness);
    final entries = <RewatchEntry>[];

    for (final lastWatched in candidates) {
      if (entries.length >= maxEntries) break;
      final showKey = lastWatched.grandparentId!;
      if (alreadyOffered.contains(showKey)) continue;

      try {
        final next = nextAfter(lastWatched, await episodesForShow(lastWatched));
        if (next == null) continue;
        entries.add(RewatchEntry(showKey: showKey, lastWatched: lastWatched, next: next));
      } catch (e) {
        // One show that cannot be resolved must not cost the whole rail: it
        // is a convenience, and a partial rail is better than none.
        appLogger.d('Could not resolve the next rewatch episode for $showKey', error: e);
      }
    }

    return entries;
  }
}
