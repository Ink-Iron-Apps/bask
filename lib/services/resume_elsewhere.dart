import '../i18n/strings.g.dart';
import '../media/media_item.dart';

/// An item whose progress was made on a different device.
class ResumeElsewhere {
  const ResumeElsewhere({required this.globalKey, required this.watchedAt, required this.age});

  final String globalKey;

  /// When the server says it was last played.
  final DateTime watchedAt;

  /// How long ago that was, at the moment the list was built.
  final Duration age;
}

/// Works out which resumable items were last played somewhere else.
///
/// The push direction — hand this to the TV — exists. The pull direction is
/// the one a household actually does hourly: stop on the TV, pick it up on the
/// phone. Continue Watching already carries the item and the position, and
/// says nothing about where the position came from, so resuming means trusting
/// a progress bar with no idea whether it is yours from this morning or last
/// night's session in the other room.
///
/// The comparison is the server's own `lastViewedAt` against this device's
/// record of what it played. Both already exist: the server keeps progress per
/// account, and [LocalPlaybackHistory] keeps what this device started. When
/// the server is meaningfully newer, the viewing happened elsewhere.
///
/// Deliberately does not name the device. Plex reports a device only for a
/// *live* session, and once playback stops that is gone; claiming "on the TV"
/// from a play-history lookup would be a second request per item for a label.
/// "Elsewhere, twenty minutes ago" is the part that changes the decision.
class ResumeElsewhereDetector {
  ResumeElsewhereDetector._();

  /// How far ahead of the local record the server must be.
  ///
  /// Progress reporting lands a little after the local record is written, and
  /// a resume on this device re-reports the same position. Anything inside
  /// this window is the same session seen twice.
  static const Duration minimumLead = Duration(minutes: 2);

  /// How recent the other-device session has to be to be worth announcing.
  ///
  /// A week-old position is just Continue Watching doing its job; the notice
  /// is for "someone was watching this a moment ago in the other room".
  static const Duration freshness = Duration(hours: 24);

  /// Items from [items] whose progress came from another device.
  ///
  /// [localLastPlayedAt] is [LocalPlaybackHistory.snapshot] — global key to
  /// epoch milliseconds. An item this device has never played counts as
  /// elsewhere, which is the common case for a phone picking up what the TV
  /// started.
  static List<ResumeElsewhere> detect({
    required Iterable<MediaItem> items,
    required Map<String, int> localLastPlayedAt,
    DateTime? now,
    Duration minimumLead = minimumLead,
    Duration freshness = freshness,
  }) {
    final at = now ?? DateTime.now();
    final out = <ResumeElsewhere>[];

    for (final item in items) {
      // Only something with a position to resume. An unwatched next episode is
      // not a handoff.
      if (!item.hasActiveProgress) continue;

      final lastViewedAt = item.lastViewedAt;
      if (lastViewedAt == null || lastViewedAt <= 0) continue;
      final watchedAt = DateTime.fromMillisecondsSinceEpoch(lastViewedAt * 1000);

      final age = at.difference(watchedAt);
      if (age.isNegative || age > freshness) continue;

      final localMs = localLastPlayedAt[item.globalKey];
      if (localMs != null) {
        final playedHere = DateTime.fromMillisecondsSinceEpoch(localMs);
        // This device played it at least as recently: the position is its own.
        if (watchedAt.difference(playedHere) < minimumLead) continue;
      }

      out.add(ResumeElsewhere(globalKey: item.globalKey, watchedAt: watchedAt, age: age));
    }

    out.sort((a, b) => a.age.compareTo(b.age));
    return out;
  }
}

/// How an [age] reads on a card.
///
/// Minutes up to an hour, then whole hours: the point is "a moment ago in the
/// other room" versus "this morning", and a precise duration would be false
/// precision over a timestamp the server rounds to the second anyway.
String formatResumeElsewhereAge(Duration age) {
  if (age.inMinutes < 1) return t.discover.watchedElsewhereJustNow;
  if (age.inMinutes < 60) return t.discover.watchedElsewhereMinutes(count: age.inMinutes.toString());
  return t.discover.watchedElsewhereHours(count: age.inHours.toString());
}
