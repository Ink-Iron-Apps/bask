import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bask/mpv/mpv.dart';
import 'package:bask/mpv/player/player_native.dart';
import 'package:bask/mpv/player/video_rect_support.dart';

import '../test_helpers/theme.dart';

/// The native-plane contract, exercised through the only thing visible from
/// outside the widget: whether it reports geometry at all.
///
/// On Windows and Linux the picture is one native plane, placed by whichever
/// [Video] reported its rect last. Two exist at once while the corner mini
/// player is up, because the full-screen route stays laid out behind it — so
/// the claim has to be exclusive, and it has to be re-sendable when it returns.
void main() {
  Widget host({required bool claims, required Player player}) => MaterialApp(
    theme: ThemeData(extensions: const [testMonoTokens]),
    home: Scaffold(
      body: SizedBox(
        width: 320,
        height: 180,
        child: Video(player: player, claimsVideoSurface: claims),
      ),
    ),
  );

  testWidgets('a claiming widget places the plane', (tester) async {
    final player = _RectRecordingPlayer();
    await tester.pumpWidget(host(claims: true, player: player));
    await tester.pump();

    expect(player.rects, isNotEmpty, reason: 'the visible widget has to place the plane');
  });

  testWidgets('a stood-down widget never moves it', (tester) async {
    final player = _RectRecordingPlayer();
    await tester.pumpWidget(host(claims: false, player: player));
    await tester.pump();

    // This is the offstage full-screen route while the mini player paints:
    // laid out, so without the claim it would fight for the plane.
    expect(player.rects, isEmpty, reason: 'an offstage route must not move the plane');
  });

  testWidgets('reclaiming re-sends identical geometry', (tester) async {
    final player = _RectRecordingPlayer();
    await tester.pumpWidget(host(claims: true, player: player));
    await tester.pump();
    final first = player.rects.length;
    expect(first, greaterThan(0));

    // Hand the plane away, then take it back at exactly the same size. The
    // dedupe cache would otherwise call this "unchanged" and leave the picture
    // where the other widget parked it — the mini player that never gives it
    // back on expand.
    await tester.pumpWidget(host(claims: false, player: player));
    await tester.pump();
    await tester.pumpWidget(host(claims: true, player: player));
    await tester.pump();

    expect(player.rects.length, greaterThan(first), reason: 'the returning owner must re-place the plane');
  });
}

/// Intercepts at [invoke] so nothing reaches a platform channel.
class _RectRecordingPlayer extends PlayerNative with VideoRectSupport {
  final List<Map<String, Object?>> rects = [];

  @override
  Future<T?> invoke<T>(String method, [dynamic args]) async {
    if (method == 'setVideoRect' && args is Map) {
      rects.add(args.cast<String, Object?>());
    }
    return null;
  }
}
