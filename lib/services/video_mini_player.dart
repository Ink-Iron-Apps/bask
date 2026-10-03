import 'package:flutter/foundation.dart';

import '../media/media_item.dart';
import '../mpv/mpv.dart';

/// Holds the player while it is shown as a corner window inside the app.
///
/// The player is a full-screen route and owns its [Player], so leaving that
/// route has always meant ending playback. A mini player needs the opposite:
/// the picture keeps going while the library is browsed. Rather than move
/// ownership out of the screen — a refactor of the most complicated screen in
/// the app — the route is put *offstage*: its state, its player and its
/// reporting stay alive, it stops painting, and it stops swallowing the clicks
/// meant for the library underneath.
///
/// What paints instead is an overlay mounted above the session's navigator,
/// beside the music mini player, bound to the same [Player]. On Windows and
/// Linux the video is a native surface positioned from whichever Video widget
/// is laid out, so handing it a corner box is all it takes to move the picture
/// there.
class VideoMiniPlayerController extends ChangeNotifier {
  VideoMiniPlayerController._();

  static final VideoMiniPlayerController instance = VideoMiniPlayerController._();

  Player? _player;
  MediaItem? _metadata;
  VoidCallback? _onExpand;
  VoidCallback? _onClose;

  /// The player to draw, or null when the mini player is not showing.
  Player? get player => _player;

  /// What is playing, for the title line.
  MediaItem? get metadata => _metadata;

  bool get isActive => _player != null;

  /// Show the mini player for [player].
  ///
  /// [onExpand] returns to the full-screen player, [onClose] ends playback;
  /// both are supplied by the player screen, which owns the route and knows
  /// how to leave it. The overlay stays ignorant of navigation.
  void enter({
    required Player player,
    required MediaItem metadata,
    required VoidCallback onExpand,
    required VoidCallback onClose,
  }) {
    _player = player;
    _metadata = metadata;
    _onExpand = onExpand;
    _onClose = onClose;
    notifyListeners();
  }

  /// Stop showing the mini player, without touching playback.
  ///
  /// Called by the player screen when it comes back on stage, and on dispose:
  /// an overlay bound to a disposed player would paint a dead surface.
  void clear() {
    if (_player == null) return;
    _player = null;
    _metadata = null;
    _onExpand = null;
    _onClose = null;
    notifyListeners();
  }

  /// Hand control back to the full-screen player.
  void expand() => _onExpand?.call();

  /// End playback from the mini player.
  void close() => _onClose?.call();

  @visibleForTesting
  void resetForTesting() => clear();
}
