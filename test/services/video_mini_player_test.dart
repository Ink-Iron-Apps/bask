import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/video_mini_player.dart';

import '../test_helpers/media_items.dart';

MediaItem _item() => testMediaItem(id: 'ep-1', backend: MediaBackend.plex, kind: MediaKind.episode, title: 'Dulcinea');

void main() {
  final controller = VideoMiniPlayerController.instance;

  tearDown(controller.resetForTesting);

  test('inactive until a player is handed over', () {
    expect(controller.isActive, isFalse);
    expect(controller.player, isNull);
  });

  test('expand and close reach the player screen that owns the route', () {
    // The overlay knows nothing about navigation on purpose: the screen owns
    // the route and is the only thing that can leave it correctly.
    var expanded = 0;
    var closed = 0;
    controller.enter(
      player: _FakePlayer(),
      metadata: testMediaItem(id: 'ep-1', backend: MediaBackend.plex, kind: MediaKind.episode, title: 'Dulcinea'),
      onExpand: () => expanded++,
      onClose: () => closed++,
    );

    expect(controller.isActive, isTrue);
    expect(controller.metadata?.displayTitle, contains('Dulcinea'));

    controller.expand();
    controller.close();

    expect(expanded, 1);
    expect(closed, 1);
  });

  test('clearing drops the player so nothing paints a dead surface', () {
    // Called from the player screen's dispose: an overlay still bound to a
    // disposed player would paint black and offer buttons that do nothing.
    controller.enter(player: _FakePlayer(), metadata: _item(), onExpand: () {}, onClose: () {});

    controller.clear();

    expect(controller.isActive, isFalse);
    expect(controller.player, isNull);
  });

  test('clearing twice notifies once', () {
    var notifications = 0;
    controller.addListener(() => notifications++);
    addTearDown(() => controller.removeListener(() => notifications++));

    controller.enter(player: _FakePlayer(), metadata: _item(), onExpand: () {}, onClose: () {});
    controller.clear();
    controller.clear();

    expect(notifications, 2, reason: 'enter and the first clear; the second is a no-op');
  });
}

/// The controller only holds the player and hands it back, so a stand-in that
/// implements nothing is enough — and avoids starting a real mpv instance in a
/// unit test.
class _FakePlayer implements Player {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
