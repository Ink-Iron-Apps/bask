import 'package:flutter_test/flutter_test.dart';
import 'package:bask/services/exact_subtitle_fetcher.dart';
import 'package:bask/models/plex/plex_subtitle_search_result.dart';

void main() {
  setUp(ExactSubtitleFetcher.resetForTesting);

  PlexSubtitleSearchResult result(String key, {bool perfect = false, double? score}) =>
      PlexSubtitleSearchResult(id: 0, key: key, perfectMatch: perfect, score: score);

  group('exactMatchIn', () {
    test('takes only a hash match, whatever the scores say', () {
      // Anchor: a high-scoring subtitle for another release can be minutes out
      // by the end of a film. Only the moviehash match is timed to this file,
      // so "best available" is the wrong rule here — it is hash or nothing.
      expect(ExactSubtitleFetcher.exactMatchIn([result('a', score: 99), result('b', perfect: true)])?.key, 'b');
      expect(ExactSubtitleFetcher.exactMatchIn([result('a', score: 99), result('c', score: 80)]), isNull);
      expect(ExactSubtitleFetcher.exactMatchIn(const []), isNull);
    });
  });
}
