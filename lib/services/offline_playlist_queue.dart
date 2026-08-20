import 'dart:math';

import '../media/media_item.dart';
import '../media/play_queue.dart';
import '../models/download_models.dart';

/// Builds a play queue from the downloads a playlist pulled in.
///
/// Playing a playlist normally asks the server to build the queue, which is no
/// use with no server: Plex materialises `/playQueues` server-side, so a
/// downloaded playlist could only ever be played an item at a time. The
/// downloads are already on the device and the sync rule already records which
/// belong to the list, so the queue can be assembled locally and handed to the
/// same client-side queue the app uses for backends without server queues.
class OfflinePlaylistQueue {
  OfflinePlaylistQueue._();

  /// Members of the playlist that are actually playable offline.
  ///
  /// Only completed downloads qualify: a queued or half-finished one has no
  /// file to play, and including it would strand playback partway through the
  /// list. Order follows [memberKeys] so the queue matches the list.
  static List<MediaItem> playableMembers({
    required Iterable<String> memberKeys,
    required Map<String, MediaItem> metadata,
    required Map<String, DownloadProgress> downloads,
  }) {
    final items = <MediaItem>[];
    for (final key in memberKeys) {
      if (downloads[key]?.status != DownloadStatus.completed) continue;
      final item = metadata[key];
      if (item != null) items.add(item);
    }
    return items;
  }

  /// A queue over [members], optionally shuffled.
  ///
  /// [startKey] names the item to begin on — tapping a specific entry plays
  /// from there while keeping the rest of the list queued behind it. When it is
  /// absent, or shuffled away, playback starts at the top.
  ///
  /// Returns null when nothing is playable, so callers can tell the difference
  /// between an empty result and a queue of one.
  static LocalPlayQueue? build({
    required String id,
    required List<MediaItem> members,
    bool shuffle = false,
    String? startKey,
    Random? random,
  }) {
    if (members.isEmpty) return null;

    var items = members;
    if (shuffle) {
      items = List.of(members);
      // Shuffling with the chosen item pinned first keeps "play this, shuffle
      // the rest" from immediately playing something else.
      if (startKey != null) {
        final index = items.indexWhere((item) => item.globalKey == startKey);
        if (index != -1) {
          final start = items.removeAt(index);
          items.shuffle(random ?? Random());
          items.insert(0, start);
          return LocalPlayQueue(id: id, items: items, currentIndex: 0, shuffled: true);
        }
      }
      items.shuffle(random ?? Random());
      return LocalPlayQueue(id: id, items: items, currentIndex: 0, shuffled: true);
    }

    final startIndex = startKey == null ? 0 : items.indexWhere((item) => item.globalKey == startKey);
    return LocalPlayQueue(id: id, items: items, currentIndex: startIndex == -1 ? 0 : startIndex, shuffled: false);
  }
}
