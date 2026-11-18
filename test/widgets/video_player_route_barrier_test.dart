import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bask/utils/video_player_navigation.dart';

/// Handing the picture to the corner mini player takes the player route
/// offstage. That is not the whole hand-off: a route's modal barrier is a
/// full-screen gesture detector with `HitTestBehavior.opaque`, and Flutter
/// ignores it only while the route is animating — so a settled offstage route
/// goes on eating every click in the window. The library was painted,
/// apparently live, and completely unresponsive.
void main() {
  testWidgets('a route holding the picture still swallows clicks when it should not', (tester) async {
    var tapsOnTheLibrary = 0;
    late NavigatorState navigator;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            navigator = Navigator.of(context);
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => tapsOnTheLibrary++,
                  child: const Text('Library'),
                ),
              ),
            );
          },
        ),
      ),
    );

    final route = VideoPlayerRoute(builder: (_) => const ColoredBox(color: Colors.black));
    unawaitedPush(navigator, route);
    await tester.pumpAndSettle();

    // Full screen: the player owns the window, and an opaque route means the
    // library is not even built, let alone clickable.
    expect(find.text('Library'), findsNothing);

    // Entering the corner mini player, in the order the player screen does it.
    route.handedToMiniPlayer = true;
    route.offstage = true;
    await tester.pumpAndSettle();

    await tester.tap(find.text('Library'));
    await tester.pump();
    expect(tapsOnTheLibrary, 1, reason: 'the mini player exists to let the library be used');

    // Expanding again takes the window back.
    route.handedToMiniPlayer = false;
    route.offstage = false;
    await tester.pumpAndSettle();

    expect(find.text('Library'), findsNothing, reason: 'the full-screen player owns the window again');
    expect(tapsOnTheLibrary, 1);
  });
}

void unawaitedPush(NavigatorState navigator, VideoPlayerRoute route) {
  route.push(navigator).ignore();
}
