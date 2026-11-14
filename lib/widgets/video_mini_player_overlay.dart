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

    return Material(
      elevation: 8,
      color: Colors.black,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Clicking the picture goes back to full screen, which is what every
          // mini player does and what nobody has to be told.
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(player: player),
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
          Padding(
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
        ],
      ),
    );
  }
}
