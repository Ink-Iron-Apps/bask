import 'package:flutter_test/flutter_test.dart';
import 'package:bask/media/media_backend.dart';
import 'package:bask/media/media_kind.dart';
import 'package:bask/services/resume_elsewhere.dart';

import '../test_helpers/media_items.dart';

void main() {
  final now = DateTime(2026, 10, 3, 20, 0);

  int secondsAt(DateTime at) => at.millisecondsSinceEpoch ~/ 1000;

  /// A resumable episode the server says was played at [watchedAt].
  dynamic episode(String id, DateTime watchedAt, {int viewOffsetMs = 600000}) => testMediaItem(
    id: id,
    backend: MediaBackend.plex,
    kind: MediaKind.episode,
    title: id,
    serverId: 'srv',
    durationMs: 2400000,
    viewOffsetMs: viewOffsetMs,
    lastViewedAt: secondsAt(watchedAt),
  );

  test('an item this device never played is a handoff', () {
    // The common case: the TV started it, the phone is picking it up.
    final detected = ResumeElsewhereDetector.detect(
      items: [episode('ep-1', now.subtract(const Duration(minutes: 8)))],
      localLastPlayedAt: const {},
      now: now,
    );

    expect(detected, hasLength(1));
    expect(detected.single.globalKey, 'srv:ep-1');
    expect(detected.single.age.inMinutes, 8);
  });

  test('progress this device made itself is not a handoff', () {
    // The local record and the server timestamp describe one session seen
    // twice: reporting lands a little after the local write.
    final watchedAt = now.subtract(const Duration(minutes: 5));
    final detected = ResumeElsewhereDetector.detect(
      items: [episode('ep-1', watchedAt)],
      localLastPlayedAt: {'srv:ep-1': watchedAt.subtract(const Duration(seconds: 20)).millisecondsSinceEpoch},
      now: now,
    );

    expect(detected, isEmpty);
  });

  test('a later session elsewhere outranks an older one here', () {
    // Watched here this morning, then somebody watched it in the other room.
    final detected = ResumeElsewhereDetector.detect(
      items: [episode('ep-1', now.subtract(const Duration(minutes: 10)))],
      localLastPlayedAt: {'srv:ep-1': now.subtract(const Duration(hours: 9)).millisecondsSinceEpoch},
      now: now,
    );

    expect(detected, hasLength(1));
  });

  test('an item with no position to resume is not announced', () {
    // A next-up episode is Continue Watching doing its job, not a handoff.
    final detected = ResumeElsewhereDetector.detect(
      items: [episode('ep-1', now.subtract(const Duration(minutes: 3)), viewOffsetMs: 0)],
      localLastPlayedAt: const {},
      now: now,
    );

    expect(detected, isEmpty);
  });

  test('a stale position is left alone', () {
    // Days old is just a resume point; the notice is for "a moment ago in the
    // other room".
    final detected = ResumeElsewhereDetector.detect(
      items: [episode('ep-1', now.subtract(const Duration(days: 3)))],
      localLastPlayedAt: const {},
      now: now,
    );

    expect(detected, isEmpty);
  });

  test('the most recent handoff comes first', () {
    final detected = ResumeElsewhereDetector.detect(
      items: [
        episode('old', now.subtract(const Duration(hours: 5))),
        episode('fresh', now.subtract(const Duration(minutes: 2))),
      ],
      localLastPlayedAt: const {},
      now: now,
    );

    expect(detected.map((entry) => entry.globalKey), ['srv:fresh', 'srv:old']);
  });

  test('a clock skew that puts the server ahead of now is ignored', () {
    expect(
      ResumeElsewhereDetector.detect(
        items: [episode('ep-1', now.add(const Duration(minutes: 5)))],
        localLastPlayedAt: const {},
        now: now,
      ),
      isEmpty,
    );
  });
}
