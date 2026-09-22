import '../media/media_item.dart';
import '../utils/search_relevance.dart';

/// Search across what is on the device, for when no server will answer.
///
/// Downloads are playable with no network at all, but finding one meant
/// scrolling the Downloads list: search itself needed a server. This is the
/// same ranking the online results use, over the items already here, so a
/// query behaves the same way in both states — it simply has less to find.
///
/// Substring matching gates what gets ranked. [rankMediaSearchResults] scores
/// everything it is handed and a zero score still comes back, which is right
/// for a server that returned matches and wrong for a local list that never
/// filtered anything.
List<MediaItem> searchDownloadedItems(Iterable<MediaItem> items, String query, {int limit = 60}) {
  final needle = normalizeSearchText(query);
  if (needle.isEmpty) return const [];

  final matches = [
    for (final item in items)
      if (_matchesAnyTitle(item, needle)) item,
  ];
  if (matches.isEmpty) return const [];

  return rankMediaSearchResults(matches, query, limit: limit);
}

/// The show's name counts as much as the episode's: offline, "the expanse" is
/// how someone asks for an episode they downloaded, and the episode's own
/// title rarely contains the show.
bool _matchesAnyTitle(MediaItem item, String needle) {
  for (final field in [item.title, item.titleSort, item.originalTitle, item.grandparentTitle, item.parentTitle]) {
    final candidate = normalizeSearchText(field);
    if (candidate.isNotEmpty && candidate.contains(needle)) return true;
  }
  return false;
}
