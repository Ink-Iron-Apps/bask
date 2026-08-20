import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/services/offline_playlist_queue.dart';
import '../test_helpers/media_items.dart';

void main() {
  MediaItem movie(String id) =>
      testMediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, title: id, serverId: ServerId('plex1'));

  DownloadProgress progress(String key, DownloadStatus status) => DownloadProgress(globalKey: key, status: status);

  final metadata = {
    for (final id in ['a', 'b', 'c']) 'plex1:$id': movie(id),
  };

  group('playableMembers', () {
    test('keeps the completed downloads, in list order', () {
      final members = OfflinePlaylistQueue.playableMembers(
        memberKeys: ['plex1:a', 'plex1:b', 'plex1:c'],
        metadata: metadata,
        downloads: {
          'plex1:a': progress('plex1:a', DownloadStatus.completed),
          'plex1:b': progress('plex1:b', DownloadStatus.completed),
          'plex1:c': progress('plex1:c', DownloadStatus.completed),
        },
      );

      expect(members.map((m) => m.id), ['a', 'b', 'c']);
    });

    test('skips anything without a finished file', () {
      // A queued or half-finished download has nothing to play, and queueing it
      // would strand playback partway through the list.
      final members = OfflinePlaylistQueue.playableMembers(
        memberKeys: ['plex1:a', 'plex1:b', 'plex1:c'],
        metadata: metadata,
        downloads: {
          'plex1:a': progress('plex1:a', DownloadStatus.completed),
          'plex1:b': progress('plex1:b', DownloadStatus.downloading),
          'plex1:c': progress('plex1:c', DownloadStatus.failed),
        },
      );

      expect(members.map((m) => m.id), ['a']);
    });

    test('skips a member whose metadata is missing', () {
      final members = OfflinePlaylistQueue.playableMembers(
        memberKeys: ['plex1:a', 'plex1:ghost'],
        metadata: metadata,
        downloads: {
          'plex1:a': progress('plex1:a', DownloadStatus.completed),
          'plex1:ghost': progress('plex1:ghost', DownloadStatus.completed),
        },
      );

      expect(members.map((m) => m.id), ['a']);
    });
  });

  group('build', () {
    List<MediaItem> members() => ['a', 'b', 'c'].map(movie).toList();

    test('nothing playable yields no queue at all', () {
      expect(OfflinePlaylistQueue.build(id: 'q', members: const []), isNull);
    });

    test('plays from the top in list order', () {
      final queue = OfflinePlaylistQueue.build(id: 'q', members: members())!;

      expect(queue.items.map((i) => i.id), ['a', 'b', 'c']);
      expect(queue.currentIndex, 0);
      expect(queue.shuffled, isFalse);
    });

    test('starts on the chosen item with the rest queued behind it', () {
      final queue = OfflinePlaylistQueue.build(id: 'q', members: members(), startKey: 'plex1:b')!;

      expect(queue.currentIndex, 1);
      expect(queue.items.map((i) => i.id), ['a', 'b', 'c']);
    });

    test('an unknown start key falls back to the top', () {
      final queue = OfflinePlaylistQueue.build(id: 'q', members: members(), startKey: 'plex1:ghost')!;

      expect(queue.currentIndex, 0);
    });

    test('shuffling keeps every item and marks the queue shuffled', () {
      final queue = OfflinePlaylistQueue.build(id: 'q', members: members(), shuffle: true, random: Random(1))!;

      expect(queue.items.map((i) => i.id).toSet(), {'a', 'b', 'c'});
      expect(queue.shuffled, isTrue);
      expect(queue.currentIndex, 0);
    });

    test('shuffling from a chosen item plays that one first', () {
      // Otherwise "play this, shuffle the rest" immediately plays something
      // else, which is not what tapping an entry means.
      for (var seed = 0; seed < 20; seed++) {
        final queue = OfflinePlaylistQueue.build(
          id: 'q',
          members: members(),
          shuffle: true,
          startKey: 'plex1:c',
          random: Random(seed),
        )!;

        expect(queue.items.first.id, 'c');
        expect(queue.items.map((i) => i.id).toSet(), {'a', 'b', 'c'});
        expect(queue.currentIndex, 0);
      }
    });

    test('a single member is a queue of one, not an empty result', () {
      final queue = OfflinePlaylistQueue.build(id: 'q', members: [movie('a')])!;

      expect(queue.items, hasLength(1));
    });
  });
}
