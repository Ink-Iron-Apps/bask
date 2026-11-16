import 'package:flutter_test/flutter_test.dart';
import 'package:bask/media/media_backend.dart';
import 'package:bask/media/media_kind.dart';
import 'package:bask/services/offline_search.dart';

import '../test_helpers/media_items.dart';

void main() {
  final expanseEpisode = testMediaItem(
    id: 'ep-1',
    backend: MediaBackend.plex,
    kind: MediaKind.episode,
    title: 'Dulcinea',
    grandparentTitle: 'The Expanse',
  );
  final expanseShow = testMediaItem(
    id: 'show-1',
    backend: MediaBackend.plex,
    kind: MediaKind.show,
    title: 'The Expanse',
  );
  final movie = testMediaItem(id: 'movie-1', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Arrival');

  test('finds an episode by the name of its show', () {
    // Offline, the show is how someone asks for the episode: its own title
    // rarely contains the series name.
    final results = searchDownloadedItems([expanseEpisode, movie], 'expanse');

    expect(results.map((item) => item.id), ['ep-1']);
  });

  test('ranks the title match above the show match', () {
    final results = searchDownloadedItems([expanseEpisode, expanseShow], 'the expanse');

    expect(results.first.id, 'show-1');
  });

  test('returns nothing rather than everything when there is no match', () {
    // The ranking scores every item it is handed, zero included, so an
    // unfiltered call would answer "no server" with the whole library.
    expect(searchDownloadedItems([expanseEpisode, movie], 'battlestar'), isEmpty);
  });

  test('an empty query is not a match-all', () {
    expect(searchDownloadedItems([expanseEpisode, movie], '   '), isEmpty);
  });

  test('ignores case, and matches accents the way the online ranking does', () {
    // normalizeSearchText folds case and Unicode typography but stays
    // accent-sensitive, so this deliberately holds the same line as the
    // ranking every online result already goes through.
    final accented = testMediaItem(id: 'movie-2', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Amélie');

    expect(searchDownloadedItems([accented], 'AMÉLIE').map((item) => item.id), ['movie-2']);
    expect(searchDownloadedItems([accented], 'amelie'), isEmpty);
  });
}
