import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bask/i18n/strings.g.dart';
import 'package:bask/mpv/mpv.dart';
import 'package:bask/mpv/player/player_native.dart';
import 'package:bask/mpv/player/video_rect_support.dart';
import 'package:bask/services/video_mini_player.dart';
import 'package:bask/widgets/video_mini_player_overlay.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/theme.dart';

/// The corner mini player shows a native plane that lives *behind* the Flutter
/// window, so what it paints decides whether anything is visible at all.
///
/// Two defects were the same defect twice: a lid over the plane. The Video
/// widget's own black background was one, and the library route — which the
/// mini player exists to make usable, and which therefore has to paint — was
/// the other. The card cuts a hole instead.
void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  testWidgets('the corner window paints no background over the picture', (tester) async {
    final player = _SilentPlayer();
    addTearDown(VideoMiniPlayerController.instance.resetForTesting);
    VideoMiniPlayerController.instance.enter(
      player: player,
      metadata: testMediaItem(title: 'Clue'),
      onExpand: () {},
      onClose: () {},
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: const Scaffold(body: Stack(children: [Positioned.fill(child: VideoMiniPlayerOverlay())])),
      ),
    );
    await tester.pump();

    final video = tester.widget<Video>(find.byType(Video));
    expect(
      video.backgroundColor,
      Colors.transparent,
      reason: 'the Video widget is handed no first frame here, so any background is a permanent lid',
    );
    expect(find.byType(CustomPaint), findsWidgets, reason: 'the card has to cut its own hole');
  });

  test('the hole is cut with a clearing blend, not painted in a colour', () {
    final canvas = _RecordingCanvas();
    const NativeSurfaceHolePainter().paint(canvas, const Size(380, 214));

    expect(canvas.blendModes, [BlendMode.clear], reason: 'anything else leaves a lid over the native plane');
  });

  test('rounded corners still clear the middle', () {
    final canvas = _RecordingCanvas();
    const NativeSurfaceHolePainter(radius: 12).paint(canvas, const Size(380, 214));

    expect(canvas.blendModes, [BlendMode.clear]);
    expect(canvas.rrects.single.outerRect, const Rect.fromLTWH(0, 0, 380, 214));
    expect(canvas.rrects.single.tlRadiusX, 12);
    // The bottom corners belong to the title bar, which has its own shape.
    expect(canvas.rrects.single.blRadiusX, 0);
  });

  test('the hole is only re-cut when its shape changes', () {
    const hole = NativeSurfaceHolePainter(radius: 12);
    expect(hole.shouldRepaint(const NativeSurfaceHolePainter(radius: 12)), isFalse);
    expect(hole.shouldRepaint(const NativeSurfaceHolePainter()), isTrue);
  });
}

/// Stands in for a real player: nothing reaches a platform channel.
class _SilentPlayer extends PlayerNative with VideoRectSupport {
  @override
  Future<T?> invoke<T>(String method, [dynamic args]) async => null;
}

/// Records what a painter asks for, which is the only way to see a blend mode:
/// a rasterised picture cannot be read back for one.
class _RecordingCanvas implements Canvas {
  final List<BlendMode> blendModes = [];
  final List<RRect> rrects = [];
  final List<Rect> rects = [];

  @override
  void drawRect(Rect rect, Paint paint) {
    rects.add(rect);
    blendModes.add(paint.blendMode);
  }

  @override
  void drawRRect(RRect rrect, Paint paint) {
    rrects.add(rrect);
    blendModes.add(paint.blendMode);
  }

  @override
  void noSuchMethod(Invocation invocation) {}
}
