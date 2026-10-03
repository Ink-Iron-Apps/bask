import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Alignment, Rect, Size;
import 'package:window_manager/window_manager.dart';

import '../utils/app_logger.dart';

/// A small always-on-top window, for a desktop that has no picture-in-picture.
///
/// Android, iOS and macOS hand the app a real PiP window; Windows and Linux
/// have no such API, so the equivalent has to be built from what a window can
/// do: shrink it, pin it above everything else, and put it out of the way. The
/// picture keeps playing in the same surface, which is the part that matters.
///
/// The previous geometry and always-on-top state are remembered on the way in
/// and restored on the way out, so leaving the mode puts the window back where
/// the user had it rather than wherever a small window happened to sit.
class DesktopMiniPlayer {
  DesktopMiniPlayer._();

  /// Width of the small window, in logical pixels.
  ///
  /// Wide enough to follow what is happening, small enough to leave the screen
  /// usable — the whole point of the mode.
  static const double miniWidth = 480;

  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  static Rect? _restoreBounds;
  static bool _restoreAlwaysOnTop = false;

  /// Only where there is no native picture-in-picture to use instead.
  static bool get isSupported => Platform.isWindows || Platform.isLinux;

  /// Enter or leave the small window.
  ///
  /// [aspectRatio] shapes it to the video so the mini window has no bars;
  /// 16:9 when the video has not reported its size yet.
  static Future<void> toggle({double aspectRatio = 16 / 9}) => active.value ? exit() : enter(aspectRatio: aspectRatio);

  static Future<void> enter({double aspectRatio = 16 / 9}) async {
    if (!isSupported || active.value) return;
    try {
      _restoreBounds = await windowManager.getBounds();
      _restoreAlwaysOnTop = await windowManager.isAlwaysOnTop();

      final ratio = aspectRatio.isFinite && aspectRatio > 0.2 && aspectRatio < 5 ? aspectRatio : 16 / 9;
      final size = Size(miniWidth, miniWidth / ratio);

      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(size);
      // Bottom-right, the corner every other picture-in-picture starts in.
      // setAlignment rather than absolute bounds: the window manager knows
      // which display the window is on and where that display's work area
      // ends, and asking it avoids a second plugin just to find out.
      await windowManager.setAlignment(Alignment.bottomRight);
      active.value = true;
      appLogger.i('Mini player: ${size.width.round()}x${size.height.round()}, pinned above other windows');
    } catch (e, stackTrace) {
      // A window manager that refuses leaves playback alone: the mode is a
      // convenience, and a half-applied one would be worse than none.
      appLogger.w('Could not enter the mini player', error: e, stackTrace: stackTrace);
      await _restore();
    }
  }

  static Future<void> exit() async {
    if (!active.value) return;
    await _restore();
  }

  static Future<void> _restore() async {
    try {
      final bounds = _restoreBounds;
      if (bounds != null) await windowManager.setBounds(bounds);
      await windowManager.setAlwaysOnTop(_restoreAlwaysOnTop);
    } catch (e) {
      appLogger.w('Could not restore the window after the mini player', error: e);
    } finally {
      _restoreBounds = null;
      active.value = false;
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _restoreBounds = null;
    _restoreAlwaysOnTop = false;
    active.value = false;
  }
}
