import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bask/media/ids.dart';
import 'package:bask/media/media_backend.dart';
import 'package:bask/media/media_item.dart';
import 'package:bask/media/media_kind.dart';
import 'package:bask/models/download_models.dart';
import 'package:bask/widgets/download_tree_view.dart';
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
    'plex1:m1': const DownloadProgress(globalKey: 'plex1:m1', status: DownloadStatus.downloading),
    'plex1:m2': const DownloadProgress(globalKey: 'plex1:m2', status: DownloadStatus.completed),
  };
  final metadata = {'plex1:m1': movie('m1', 'Busy Movie'), 'plex1:m2': movie('m2', 'Done Movie')};

  Future<void> pumpTree(WidgetTester tester, {List<String>? paused, List<String>? deleted}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadTreeView(
            downloads: downloads,
            metadata: metadata,
            suppressAutoFocus: true,
            onPause: (key) => paused?.add(key),
            onDelete: (key) => deleted?.add(key),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the list is not in selection mode until asked', (tester) async {
    await pumpTree(tester);

    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('a long press starts selecting and selects that row', (tester) async {
    await pumpTree(tester);

    await tester.longPress(find.text('Busy Movie'));
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsWidgets);
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('tapping another row while selecting adds it', (tester) async {
    await pumpTree(tester);

    await tester.longPress(find.text('Busy Movie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done Movie'));
    await tester.pumpAndSettle();

    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('a bulk action reaches only the downloads that can take it', (tester) async {
    final paused = <String>[];
    await pumpTree(tester, paused: paused);

    await tester.longPress(find.text('Busy Movie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done Movie'));
    await tester.pumpAndSettle();

    // Both are selected, but only the downloading one can be paused.
    await tester.tap(find.byTooltip('Pause selected'));
    await tester.pumpAndSettle();

    expect(paused, ['plex1:m1']);
  });

  testWidgets('deselecting the last row leaves selection mode', (tester) async {
    await pumpTree(tester);

    await tester.longPress(find.text('Busy Movie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Busy Movie'));
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('close leaves selection without acting', (tester) async {
    final deleted = <String>[];
    await pumpTree(tester, deleted: deleted);

    await tester.longPress(find.text('Busy Movie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsNothing);
    expect(deleted, isEmpty);
  });
}
