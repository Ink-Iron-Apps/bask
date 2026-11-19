import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../mpv/mpv.dart';
import '../services/video_mini_player.dart';
import '../theme/mono_tokens.dart';
import '../utils/platform_detector.dart';
import 'app_icon.dart';

/// The corner window the video plays in while the rest of the app is used.
///
/// Mounted above the session's navigator, beside the music mini player, so it
/// survives every content route. Desktop only: Android, iOS and macOS hand the
/// app a real picture-in-picture window, which is better than anything drawn
/// inside it.
class VideoMiniPlayerOverlay extends StatelessWidget {
  const VideoMiniPlayerOverlay({super.key});

  /// Width of the corner window, matching the music mini player's so the two
  /// cannot disagree about where the corner is.
  static const double width = 380;

  /// Corner radius of the card, applied to the cut-out as well as the title
  /// bar so the two halves agree about the shape.
  static const double radius = 12;

  @override
  Widget build(BuildContext context) {
    if (!PlatformDetector.isDesktopOS()) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: VideoMiniPlayerController.instance,
      builder: (context, _) {
        final controller = VideoMiniPlayerController.instance;
        final player = controller.player;
        if (player == null) return const SizedBox.shrink();

        return Stack(
          children: [
            Positioned(
              right: 16,
              // Above the music mini player's own corner, so a music session
              // and a video session do not land on top of each other.
              bottom: 16,
              width: width,
              child: _MiniVideoCard(player: player, title: controller.metadata?.displayTitle ?? ''),
            ),
          ],
        );
      },
    );
  }
}

class _MiniVideoCard extends StatelessWidget {
  const _MiniVideoCard({required this.player, required this.title});

  final Player player;
  final String title;

  @override
  Widget build(BuildContext context) {
    final controller = VideoMiniPlayerController.instance;
    final monoTokens = tokens(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Clicking the picture goes back to full screen, which is what every
        // mini player does and what nobody has to be told.
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Painted before anything else in this rect and after everything
              // underneath it, which is the whole job: see
              // [NativeSurfaceHolePainter].
              const CustomPaint(painter: NativeSurfaceHolePainter(radius: VideoMiniPlayerOverlay.radius)),
              // Transparent, not black. The picture is a native plane behind
              // the window, so the Video widget's own background would be an
              // opaque lid on it — and this widget is handed no first-frame
              // signal to lift that lid with. What it is here for is the
              // layout: the plane is placed wherever this is laid out.
              Video(player: player, backgroundColor: Colors.transparent),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: controller.expand,
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
        // The title row brings its own fill, and its own shape: a Material
        // around the picture would not do, because elevation and a clip put
        // the cut-out inside a layer of their own, where erasing pixels erases
        // that layer instead of the app behind it.
        ClipRRect(
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(VideoMiniPlayerOverlay.radius)),
          child: Material(
            elevation: 8,
            color: monoTokens.surface,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: monoTokens.textMuted),
                    ),
                  ),
                  // Pause belongs here: the whole point of the corner window is
                  // that the rest of the app is in use, and expanding back to
                  // full screen just to pause defeats it.
                  StreamBuilder<bool>(
                    stream: player.streams.playing,
                    initialData: player.state.playing,
                    builder: (context, snapshot) {
                      final playing = snapshot.data ?? false;
                      return IconButton(
                        icon: AppIcon(playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded, fill: 1, size: 20),
                        tooltip: playing ? t.videoControls.pauseButton : t.videoControls.playButton,
                        onPressed: () => playing ? player.pause() : player.play(),
                      );
                    },
                  ),
                  IconButton(
                    icon: const AppIcon(Symbols.fullscreen_rounded, fill: 1, size: 20),
                    tooltip: t.videoControls.fullscreenButton,
                    onPressed: controller.expand,
                  ),
                  IconButton(
                    icon: const AppIcon(Symbols.close_rounded, fill: 1, size: 20),
                    tooltip: t.common.close,
                    onPressed: controller.close,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Erases what the app painted where the video plane is.
///
/// On Windows and Linux the picture is a native surface *behind* the Flutter
/// window — a child HWND under the engine's topmost DComp visual, a
/// `wl_subsurface` placed below the parent — so it is visible exactly where
/// Flutter leaves the window transparent. Full screen gets that for free: the
/// route is opaque, nothing below it is allowed to paint, and nothing in it
/// paints either.
///
/// The corner window is the opposite case on purpose. The library underneath
/// has to be painted and usable, and every pixel it paints is a pixel the
/// plane cannot be seen through. So the card cuts its own hole: the pixels in
/// this rect are cleared back to transparent after the app has drawn them, and
/// the plane shows through.
///
/// Nothing may paint over this afterwards. A background on the Video widget, a
/// shadow, a scrim, a Material behind the picture — any of them is a lid, and
/// the symptom is a corner window with sound and no video.
class NativeSurfaceHolePainter extends CustomPainter {
  const NativeSurfaceHolePainter({this.radius = 0});

  /// Rounds the top corners, which are the card's own corners. A rounded
  /// corner here is a corner the hole does not cover, so the app shows through
  /// it — which is what makes the shape read as a rounded card.
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final clear = Paint()..blendMode = BlendMode.clear;
    if (radius <= 0) {
      canvas.drawRect(Offset.zero & size, clear);
      return;
    }
    canvas.drawRRect(
      RRect.fromRectAndCorners(Offset.zero & size, topLeft: Radius.circular(radius), topRight: Radius.circular(radius)),
      clear,
    );
  }

  @override
  bool shouldRepaint(covariant NativeSurfaceHolePainter oldDelegate) => oldDelegate.radius != radius;
}
