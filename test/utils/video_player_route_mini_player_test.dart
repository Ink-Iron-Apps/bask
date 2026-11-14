import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/video_player_navigation.dart';

/// Handing the picture to the corner player has to let the routes underneath
/// paint again.
///
/// Flutter assigns the overlay entry's opacity from the route's own `opaque`
/// with no `offstage` term, so an offstage-but-opaque player route stops
/// painting *and* keeps suppressing everything below it. That is a window with
/// nothing in it — the bug this pins.
void main() {
  testWidgets('the route stops being opaque while the mini player has the picture', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('library')),
      ),
    );

    final route = VideoPlayerRoute(builder: (_) => const Scaffold(body: Text('player')));
    route.push(navigatorKey.currentState!).ignore();
    await tester.pumpAndSettle();

    expect(route.opaque, isTrue, reason: 'a full-screen player covers what is behind it');
    expect(route.overlayEntries.first.opaque, isTrue);

    route.handedToMiniPlayer = true;
    await tester.pump();

    expect(route.opaque, isFalse, reason: 'the library underneath has to be allowed to paint');
    expect(
      route.overlayEntries.first.opaque,
      isFalse,
      reason: 'the entry has to be updated now: only a status change ever refreshes it, and none is coming',
    );

    route.handedToMiniPlayer = false;
    await tester.pump();

    expect(route.opaque, isTrue);
    expect(route.overlayEntries.first.opaque, isTrue, reason: 'expanding restores a covering player');
  });

  testWidgets('setting the same value twice does not churn the overlay', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('library')),
      ),
    );
    final route = VideoPlayerRoute(builder: (_) => const Scaffold(body: Text('player')));
    route.push(navigatorKey.currentState!).ignore();
    await tester.pumpAndSettle();

    route.handedToMiniPlayer = true;
    await tester.pump();
    route.handedToMiniPlayer = true;
    await tester.pump();

    expect(route.overlayEntries.first.opaque, isFalse);
  });
}
