import 'package:flutter_test/flutter_test.dart';
import 'package:bask/i18n/strings.g.dart';
import 'package:bask/media/media_item.dart';
import 'package:bask/media/media_item_labels.dart';
import 'package:bask/media/media_kind.dart';

void main() {
  MediaItem item({
    MediaKind kind = MediaKind.movie,
    String? grandparentTitle,
    int? parentIndex,
    int? index,
    int? year,
    String? editionTitle,
  }) => MediaItem.plex(
    id: 'item',
    kind: kind,
    grandparentTitle: grandparentTitle,
    parentIndex: parentIndex,
    index: index,
    year: year,
    editionTitle: editionTitle,
  );

  test('formats episodes with show and season/episode numbers', () {
    expect(
      formatQueueItemSubtitle(item(kind: MediaKind.episode, grandparentTitle: 'Show', parentIndex: 2, index: 3)),
      'Show \u00b7 S2E3',
    );
  });

  test('falls back through show, year and edition, then media kind', () {
    expect(formatQueueItemSubtitle(item(grandparentTitle: 'Show')), 'Show');
    expect(formatQueueItemSubtitle(item(year: 2026, editionTitle: 'Director Cut')), '2026 \u00b7 Director Cut');
    expect(formatQueueItemSubtitle(item(year: 2026)), '2026');
    expect(formatQueueItemSubtitle(item()), t.common.mediaKind.movie);
  });

  group('formatDownloadNotificationName', () {
    MediaItem episode({String? title, int? season, int? number}) => MediaItem.plex(
      id: 'ep',
      kind: MediaKind.episode,
      title: title,
      grandparentTitle: 'Ted Lasso',
      parentIndex: season,
      index: number,
    );

    test('names the show, the season and episode, and the episode title', () {
      // The notification used to read "Ted Lasso - Ted Lasso": displayTitle
      // collapses an episode to its show, so it was paired with itself.
      expect(
        formatDownloadNotificationName(episode(title: 'Pilot', season: 1, number: 1)),
        'Ted Lasso · S1 E1 · Pilot',
      );
    });

    test('drops the numbers when the row does not carry them', () {
      expect(formatDownloadNotificationName(episode(title: 'Pilot')), 'Ted Lasso · Pilot');
    });

    test('a movie keeps its own title', () {
      expect(formatDownloadNotificationName(MediaItem.plex(id: 'm', kind: MediaKind.movie, title: 'Heat')), 'Heat');
    });

    test('a track leads with its artist', () {
      expect(
        formatDownloadNotificationName(
          MediaItem.plex(id: 't', kind: MediaKind.track, title: 'Song', originalTitle: 'Artist'),
        ),
        'Artist - Song',
      );
    });
  });
}
