import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/services/auto_download_planner.dart';

import '../test_helpers/media_items.dart';

SyncRuleItem _rule({required String globalKey, required String ratingKey, bool managed = false}) => SyncRuleItem(
  id: globalKey.hashCode,
  profileId: 'profile-a',
  serverId: 'server-1',
  ratingKey: ratingKey,
  globalKey: globalKey,
  targetType: 'show',
  episodeCount: 2,
  enabled: true,
  createdAt: 0,
  mediaIndex: 0,
  downloadFilter: 'next_in_order',
  includeSpecials: true,
  downloadLinksInitialized: false,
  managed: managed,
);

String _keyFor(ServerId serverId, String ratingKey) => 'profile-a|$serverId:$ratingKey';

void main() {
  test('names the shows behind Continue Watching, most recent first', () {
    final targets = AutoDownloadPlanner.showsInProgress([
      testMediaItem(
        id: 'ep-9',
        kind: MediaKind.episode,
        backend: MediaBackend.plex,
        grandparentId: 'show-b',
        grandparentTitle: 'Show B',
        serverId: 'server-1',
      ),
      testMediaItem(
        id: 'ep-1',
        kind: MediaKind.episode,
        backend: MediaBackend.plex,
        grandparentId: 'show-a',
        grandparentTitle: 'Show A',
        serverId: 'server-1',
      ),
      // Same show again: one rule covers however many of its episodes are
      // sitting in the list.
      testMediaItem(
        id: 'ep-2',
        kind: MediaKind.episode,
        backend: MediaBackend.plex,
        grandparentId: 'show-a',
        serverId: 'server-1',
      ),
      // A film has no next episode to keep ahead of.
      testMediaItem(id: 'movie-1', kind: MediaKind.movie, backend: MediaBackend.plex, serverId: 'server-1'),
    ]);

    expect(targets.map((t) => t.showId), ['show-b', 'show-a']);
    expect(targets.first.title, 'Show B');
  });

  test('stops at the limit rather than covering a whole shared server', () {
    final targets = AutoDownloadPlanner.showsInProgress([
      for (var i = 0; i < 20; i++)
        testMediaItem(
          id: 'ep-$i',
          kind: MediaKind.episode,
          backend: MediaBackend.plex,
          grandparentId: 'show-$i',
          serverId: 'server-1',
        ),
    ], limit: 3);

    expect(targets, hasLength(3));
  });

  test('adds what is missing and drops what has left Continue Watching', () {
    final plan = AutoDownloadPlanner.reconcile(
      targets: [
        AutoDownloadTarget(serverId: ServerId('server-1'), showId: 'show-a'),
        AutoDownloadTarget(serverId: ServerId('server-1'), showId: 'show-new'),
      ],
      existingRules: [
        _rule(globalKey: 'profile-a|server-1:show-a', ratingKey: 'show-a', managed: true),
        _rule(globalKey: 'profile-a|server-1:show-gone', ratingKey: 'show-gone', managed: true),
      ],
      keyFor: _keyFor,
    );

    expect(plan.create.map((t) => t.showId), ['show-new']);
    expect(plan.remove, ['profile-a|server-1:show-gone']);
  });

  test("never touches a rule the user made, for a show it also wants", () {
    // Their rule may keep every episode, or a different count; replacing it
    // would quietly change what they chose to keep.
    final plan = AutoDownloadPlanner.reconcile(
      targets: [AutoDownloadTarget(serverId: ServerId('server-1'), showId: 'show-a')],
      existingRules: [_rule(globalKey: 'profile-a|server-1:show-a', ratingKey: 'show-a')],
      keyFor: _keyFor,
    );

    expect(plan.isEmpty, isTrue);
  });

  test('leaves rules the user made for other shows alone', () {
    final plan = AutoDownloadPlanner.reconcile(
      targets: const [],
      existingRules: [_rule(globalKey: 'profile-a|server-1:show-theirs', ratingKey: 'show-theirs')],
      keyFor: _keyFor,
    );

    expect(plan.remove, isEmpty);
  });

  test('the managed column survives a round trip', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.insertSyncRule(
      profileId: 'profile-a',
      serverId: ServerId('server-1'),
      ratingKey: 'show-a',
      globalKey: 'profile-a|server-1:show-a',
      targetType: 'show',
      episodeCount: 2,
      downloadFilter: 'next_in_order',
      managed: true,
      title: 'Show A',
    );

    final stored = await db.getSyncRule('profile-a|server-1:show-a');
    expect(stored?.managed, isTrue);
    expect(stored?.title, 'Show A');
  });
}
