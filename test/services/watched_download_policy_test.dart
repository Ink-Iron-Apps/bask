import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/sync_rule_executor.dart';
import 'package:plezy/services/watched_download_policy.dart';

void main() {
  test('an unwatched rule gives up its watched copies, whatever the preference says', () {
    // The rule exists to hold what is still to watch. Keeping the episode the
    // viewer just finished contradicts it, and the rule would count that copy
    // toward its own target instead of fetching ahead.
    expect(
      decideWatchedDownload(coveringFilters: const [SyncRuleFilter.unwatched], removeWatchedDownloads: false),
      WatchedDownloadVerdict.remove,
    );
  });

  test('a next-in-order rule behaves the same way', () {
    expect(
      decideWatchedDownload(coveringFilters: const [SyncRuleFilter.nextInOrder], removeWatchedDownloads: false),
      WatchedDownloadVerdict.remove,
    );
  });

  test('a rule mirroring everything keeps its watched copies, preference on', () {
    // Deleting out from under it only makes the next pass download the file
    // again.
    expect(
      decideWatchedDownload(coveringFilters: const [SyncRuleFilter.all], removeWatchedDownloads: true),
      WatchedDownloadVerdict.keep,
    );
  });

  test('mirroring everything wins over a window covering the same item', () {
    // A show kept as a rolling window and a collection mirrored in full can
    // both cover one episode; the broader request is the unambiguous one.
    expect(
      decideWatchedDownload(
        coveringFilters: const [SyncRuleFilter.unwatched, SyncRuleFilter.all],
        removeWatchedDownloads: false,
      ),
      WatchedDownloadVerdict.keep,
    );
  });

  test('a download no rule covers follows the preference', () {
    expect(
      decideWatchedDownload(coveringFilters: const [], removeWatchedDownloads: true),
      WatchedDownloadVerdict.remove,
    );
    expect(
      decideWatchedDownload(coveringFilters: const [], removeWatchedDownloads: false),
      WatchedDownloadVerdict.keep,
    );
  });

  test('an unrecognized filter is not read as a request to delete', () {
    // A filter this build does not know about could mean anything; falling
    // back to the preference is the answer that cannot lose someone's file.
    expect(
      decideWatchedDownload(coveringFilters: const ['something-new'], removeWatchedDownloads: false),
      WatchedDownloadVerdict.keep,
    );
  });
}
