import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bask/media/ids.dart';
import 'package:bask/media/media_backend.dart';
import 'package:bask/media/media_item.dart';
import 'package:bask/media/media_kind.dart';
import 'package:bask/models/download_models.dart';
import 'package:bask/widgets/download_tree_view.dart';

import '../test_helpers/media_items.dart';

/// Android takes taps in the strip it reserves for the back gesture before the
/// app sees them, so a row laid out there looks live and does nothing. That
/// was real: on a 1600-pixel tablet a downloads row occupying 1491 to 1600 was
/// untappable while one at 1369 to 1491 worked, and a show group that happened
/// to sit last simply refused to expand with nothing in the log.
void main() {
  const screen = Size(800, 600);
  const insetHeight = 48.0;

  MediaItem movie(String id, String title) => testMediaItem(
    id: id,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: title,
    serverId: ServerId('plex1'),
  );

  // Enough rows to overflow the viewport, so the last one is at the bottom
  // edge rather than floating in the middle of an empty list.
  final downloads = <String, DownloadProgress>{
    for (var i = 0; i < 20; i++)
      'plex1:m$i': DownloadProgress(globalKey: 'plex1:m$i', status: DownloadStatus.completed),
  };
  final metadata = <String, MediaItem>{for (var i = 0; i < 20; i++) 'plex1:m$i': movie('m$i', 'Movie $i')};

  Future<void> pumpTree(WidgetTester tester) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          // A device with a gesture strip along the bottom.
          data: const MediaQueryData(
            size: screen,
            viewPadding: EdgeInsets.only(bottom: insetHeight),
            padding: EdgeInsets.only(bottom: insetHeight),
            systemGestureInsets: EdgeInsets.only(bottom: insetHeight),
          ),
          child: Scaffold(
            body: DownloadTreeView(downloads: downloads, metadata: metadata, suppressAutoFocus: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the list ends above the gesture strip', (tester) async {
    await pumpTree(tester);

    // The viewport itself, not the content inside it: padding the content only
    // moved the problem, because expanding a group inserts rows below the one
    // that was tapped and each expansion pushed a fresh row into the strip.
    final viewport = tester.renderObject<RenderBox>(find.byType(Scrollable).first);
    final bottom = viewport.localToGlobal(Offset(0, viewport.size.height)).dy;

    expect(
      bottom,
      lessThanOrEqualTo(screen.height - insetHeight),
      reason: 'rows laid out below ${screen.height - insetHeight} are in the strip Android takes taps in',
    );
  });

  testWidgets('everything past the fold is still reachable, and reachable above the strip', (tester) async {
    // The shrunk viewport must not become a shrunk list: the half a fixed safe
    // area gets wrong is leaving the tail unreachable instead of untappable.
    await pumpTree(tester);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await tester.pumpAndSettle();

    final last = find.text('Movie 19');
    expect(last, findsOneWidget);

    final box = tester.renderObject<RenderBox>(last);
    final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    expect(
      bottom,
      lessThanOrEqualTo(screen.height - insetHeight),
      reason: 'the last row has to come to rest somewhere it can be tapped',
    );
  });
}
