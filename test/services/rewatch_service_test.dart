import 'package:flutter_test/flutter_test.dart';
import 'package:bask/media/media_item.dart';
import 'package:bask/media/media_kind.dart';
import 'package:bask/services/rewatch_service.dart';

import '../test_helpers/media_items.dart';

void main() {
  final now = DateTime.utc(2026, 9, 17, 12);
  int secondsAgo(Duration d) => (now.subtract(d).millisecondsSinceEpoch) ~/ 1000;

  MediaItem episode(
    String id, {
    required String show,
    required int season,
    required int number,
    int? watchedAgoDays,
    int viewCount = 1,
  }) {
    return testMediaItem(
      id: id,
      kind: MediaKind.episode,
      grandparentId: show,
      parentIndex: season,
      index: number,
      viewCount: viewCount,
      lastViewedAt: watchedAgoDays == null ? null : secondsAgo(Duration(days: watchedAgoDays)),
    );
  }

  group('mostRecentPerShow', () {
    test('keeps the newest episode of each show, newest show first', () {
      final items = [
        episode('a1', show: 'A', season: 1, number: 1, watchedAgoDays: 5),
        episode('a2', show: 'A', season: 1, number: 2, watchedAgoDays: 2),
        episode('b1', show: 'B', season: 1, number: 1, watchedAgoDays: 1),
      ];

      final result = RewatchService.mostRecentPerShow(items, now: now);

      expect(result.map((e) => e.id), ['b1', 'a2']);
    });

    test('drops episodes never played', () {
      final items = [episode('a1', show: 'A', season: 1, number: 1, viewCount: 0)];
      expect(RewatchService.mostRecentPerShow(items, now: now), isEmpty);
    });

    test('drops a rewatch that has gone stale', () {
      // Anchor: a series finished months ago should not sit on the home
      // screen forever, but a fortnight's break must survive.
      final recent = episode('a1', show: 'A', season: 1, number: 1, watchedAgoDays: 14);
      final stale = episode('b1', show: 'B', season: 1, number: 1, watchedAgoDays: 60);

      final result = RewatchService.mostRecentPerShow([recent, stale], now: now);

      expect(result.map((e) => e.id), ['a1']);
    });
  });

  group('nextAfter', () {
    test('offers the following episode in watch order', () {
      final e1 = episode('a1', show: 'A', season: 1, number: 1, watchedAgoDays: 1);
      final e2 = episode('a2', show: 'A', season: 1, number: 2);
      expect(RewatchService.nextAfter(e1, [e2, e1])?.id, 'a2');
    });

    test('offers nothing at the end of a show', () {
      // The rewatch is over; restarting it uninvited is not "next".
      final e1 = episode('a1', show: 'A', season: 1, number: 1);
      final e2 = episode('a2', show: 'A', season: 1, number: 2, watchedAgoDays: 1);
      expect(RewatchService.nextAfter(e2, [e1, e2]), isNull);
    });
  });

  group('build', () {
    test('skips shows the server already offers', () async {
      // Anchor: a show mid-season is Continue Watching's job. Listing it
      // twice would have the app arguing with the server about what is next.
      final a1 = episode('a1', show: 'A', season: 1, number: 1, watchedAgoDays: 1);
      final a2 = episode('a2', show: 'A', season: 1, number: 2);

      final entries = await RewatchService.build(
        recentlyWatched: [a1],
        episodesForShow: (_) async => [a1, a2],
        alreadyOffered: {'A'},
        now: now,
      );

      expect(entries, isEmpty);
    });

    test('a show that cannot be resolved does not cost the rail', () async {
      final a1 = episode('a1', show: 'A', season: 1, number: 1, watchedAgoDays: 2);
      final b1 = episode('b1', show: 'B', season: 1, number: 1, watchedAgoDays: 1);
      final b2 = episode('b2', show: 'B', season: 1, number: 2);

      final entries = await RewatchService.build(
        recentlyWatched: [a1, b1],
        episodesForShow: (last) async {
          if (last.grandparentId == 'A') throw StateError('server said no');
          return [b1, b2];
        },
        now: now,
      );

      expect(entries.map((e) => e.next.id), ['b2']);
    });

    test('stops at the entry cap rather than fetching every show', () async {
      var fetches = 0;
      final watched = [
        for (var i = 0; i < 10; i++) episode('e$i', show: 'S$i', season: 1, number: 1, watchedAgoDays: i + 1),
      ];

      final entries = await RewatchService.build(
        recentlyWatched: watched,
        episodesForShow: (last) async {
          fetches++;
          return [last, episode('next-${last.grandparentId}', show: last.grandparentId!, season: 1, number: 2)];
        },
        maxEntries: 3,
        now: now,
      );

      expect(entries, hasLength(3));
      expect(fetches, 3, reason: 'each resolution is a server round trip');
    });
  });
}
