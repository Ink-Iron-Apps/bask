import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/screens/downloads/downloaded_playlists_tab.dart';
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

  final metadata = {'plex1:m1': movie('m1', 'First'), 'plex1:m2': movie('m2', 'Second')};

  Future<List<bool>> pump(
    WidgetTester tester, {
    required Map<String, DownloadProgress> downloads,
    String? tapTooltip,
    List<DownloadPlaylistGroup>? playlists,
  }) async {
    final shuffles = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadedPlaylistsTab(
            playlists:
                playlists ??
                const [
                  DownloadPlaylistGroup(key: 'plex1:pl9', title: 'Road Trip', memberKeys: {'plex1:m1', 'plex1:m2'}),
                ],
            metadata: metadata,
            downloads: downloads,
            suppressAutoFocus: true,
            onPlay: (playlist, {required shuffle}) => shuffles.add(shuffle),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (tapTooltip != null) {
      await tester.tap(find.byTooltip(tapTooltip));
      await tester.pumpAndSettle();
    }
    return shuffles;
  }

  final bothDownloaded = {
    'plex1:m1': const DownloadProgress(globalKey: 'plex1:m1', status: DownloadStatus.completed),
    'plex1:m2': const DownloadProgress(globalKey: 'plex1:m2', status: DownloadStatus.completed),
  };

  testWidgets('a downloaded playlist plays in order', (tester) async {
    expect(await pump(tester, downloads: bothDownloaded, tapTooltip: 'Play'), [false]);
  });

  testWidgets('a downloaded playlist shuffles', (tester) async {
    expect(await pump(tester, downloads: bothDownloaded, tapTooltip: 'Shuffle'), [true]);
  });

  testWidgets('the row counts only what has finished downloading', (tester) async {
    await pump(
      tester,
      downloads: {
        'plex1:m1': const DownloadProgress(globalKey: 'plex1:m1', status: DownloadStatus.completed),
        'plex1:m2': const DownloadProgress(globalKey: 'plex1:m2', status: DownloadStatus.downloading),
      },
    );

    expect(find.text('1 downloaded'), findsOneWidget);
  });

  testWidgets('a playlist with nothing finished cannot be played', (tester) async {
    await pump(
      tester,
      downloads: {
        'plex1:m1': const DownloadProgress(globalKey: 'plex1:m1', status: DownloadStatus.downloading),
        'plex1:m2': const DownloadProgress(globalKey: 'plex1:m2', status: DownloadStatus.queued),
      },
    );

    final play = tester.widget<IconButton>(
      find.ancestor(of: find.byTooltip('Play'), matching: find.byType(IconButton)).first,
    );
    expect(play.onPressed, isNull, reason: 'nothing to play yet');
  });
}
