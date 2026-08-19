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

  Future<void> pump(WidgetTester tester, DownloadStatus status, {Size size = const Size(360, 640)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadTreeView(
            downloads: {'plex1:m1': DownloadProgress(globalKey: 'plex1:m1', status: status)},
            metadata: {'plex1:m1': movie('m1', 'A Movie With A Fairly Long Title')},
            suppressAutoFocus: true,
            onPause: (_) {},
            onResume: (_) {},
            onRetry: (_) {},
            onDelete: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a row action is at least the minimum comfortable tap target', (tester) async {
    await pump(tester, DownloadStatus.downloading);

    // The icon alone used to be the whole target, which is what made these hard
    // to hit on a dense list.
    final target = tester.getSize(find.descendant(of: find.byTooltip('Pause'), matching: find.byType(SizedBox)).first);

    expect(target.width, greaterThanOrEqualTo(48.0));
    expect(target.height, greaterThanOrEqualTo(48.0));
  });

  testWidgets('tapping inside the padding, not just the glyph, triggers the action', (tester) async {
    final paused = <String>[];
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadTreeView(
            downloads: {'plex1:m1': const DownloadProgress(globalKey: 'plex1:m1', status: DownloadStatus.downloading)},
            metadata: {'plex1:m1': movie('m1', 'A Movie')},
            suppressAutoFocus: true,
            onPause: paused.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Near the corner of the target, well outside the 22dp glyph.
    final rect = tester.getRect(find.descendant(of: find.byTooltip('Pause'), matching: find.byType(SizedBox)).first);
    await tester.tapAt(Offset(rect.left + 4, rect.top + 4));
    await tester.pumpAndSettle();

    expect(paused, ['plex1:m1']);
  });

  testWidgets('a failed row fits its four actions without overflowing', (tester) async {
    await pump(tester, DownloadStatus.failed, size: const Size(320, 640));

    expect(tester.takeException(), isNull);
  });
}
