import 'sync_rule_executor.dart';

/// What to do with a downloaded item that has just become watched.
enum WatchedDownloadVerdict { remove, keep }

/// Decide the fate of a watched download from the rules that cover it.
///
/// A sync rule already states what it wants kept, and a watched episode is
/// outside what an unwatched rule asked for: the rule exists to hold what is
/// still to watch, so leaving the watched copy behind contradicts it, and the
/// rule would otherwise count that copy toward its own target and stop
/// fetching ahead. The same reasoning in reverse protects a rule that asked
/// for everything — deleting a watched episode out from under it only makes it
/// download the file again on the next pass.
///
/// [removeWatchedDownloads] — the global "Remove watched downloads" setting —
/// decides the rest: a download nobody's rule covers, queued by hand, has only
/// that preference to go on.
WatchedDownloadVerdict decideWatchedDownload({
  required Iterable<String> coveringFilters,
  required bool removeWatchedDownloads,
}) {
  var coveredByWindow = false;

  for (final filter in coveringFilters) {
    // Mirroring the whole list wins over any window: it is the broader
    // request, and a rule that wants watched episodes on the device is not
    // ambiguous about it.
    if (filter == SyncRuleFilter.all) return WatchedDownloadVerdict.keep;
    if (filter == SyncRuleFilter.unwatched || filter == SyncRuleFilter.nextInOrder) coveredByWindow = true;
  }

  if (coveredByWindow) return WatchedDownloadVerdict.remove;
  return removeWatchedDownloads ? WatchedDownloadVerdict.remove : WatchedDownloadVerdict.keep;
}
