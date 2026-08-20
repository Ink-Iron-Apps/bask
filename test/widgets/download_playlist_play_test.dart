import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/widgets/download_tree_view.dart';
import '../test_helpers/media_items.dart';

void main() {
  MediaItem movie(String id, String title) => testMediaItem(
    id: id,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: title,
    serverId: ServerId('plex1'),
  );

  final downloads = {
    'plex1:m1': const DownloadProgress(globalKey: 'plex1:m1', status: DownloadStatus.completed),
    'plex1:m2': const DownloadProgress(globalKey: 'plex1:m2', status: DownloadStatus.completed),
  };
  final metadata = {'plex1:m1': movie('m1', 'First'), 'plex1:m2': movie('m2', 'Second')};

  Future<List<bool>> pumpAndTap(WidgetTester tester, String tooltip, {bool withPlaylist = true}) async {
    final shuffles = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadTreeView(
            downloads: downloads,
            metadata: metadata,
            suppressAutoFocus: true,
            playlists: withPlaylist
                ? [
                    const DownloadPlaylistGroup(
                      key: 'plex1:pl9',
                      title: 'Road Trip',
                      memberKeys: {'plex1:m1', 'plex1:m2'},
                    ),
                  ]
                : const [],
            onPlayPlaylist: (playlist, {required shuffle}) => shuffles.add(shuffle),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (tooltip.isNotEmpty) {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
    }
    return shuffles;
  }

  testWidgets('a downloaded playlist offers play', (tester) async {
    expect(await pumpAndTap(tester, 'Play'), [false]);
  });

  testWidgets('a downloaded playlist offers shuffle', (tester) async {
    expect(await pumpAndTap(tester, 'Shuffle'), [true]);
  });

  testWidgets('a plain download is not offered playlist playback', (tester) async {
    await pumpAndTap(tester, '', withPlaylist: false);

    // Movies outside a playlist have no queue to start.
    expect(find.byTooltip('Shuffle'), findsNothing);
  });
}
