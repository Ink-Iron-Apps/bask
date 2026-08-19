import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_logger.dart';
import 'platform_detector.dart';

class OrientationHelper {
  static const MethodChannel _deviceChannel = MethodChannel('com.plezy/device');

  /// Whether the player should turn with the device even with the system
  /// rotation lock on.
  ///
  /// [SystemChrome.setPreferredOrientations] cannot express this: Flutter maps
  /// a full set of orientations to Android's SCREEN_ORIENTATION_FULL_USER,
  /// which obeys the lock, so a phone with auto-rotate off stays fixed however
  /// it is held. The native side switches to FULL_SENSOR instead, and back when
  /// the player closes so the rest of the app keeps honouring the lock.
  static Future<void> setFollowSensorOrientation(bool follow) async {
    if (!Platform.isAndroid || PlatformDetector.isAutomotive()) return;
    try {
      await _deviceChannel.invokeMethod<bool>('setFollowSensorOrientation', follow);
    } catch (e) {
      // An older host without the handler simply keeps the previous behaviour.
      appLogger.d('Could not set sensor orientation follow to $follow', error: e);
    }
  }

  /// Restores default orientation preferences based on device type.
  ///
  /// For phones: Locks to portrait-only (up and down)
  /// For tablets/desktop: Allows all orientations
  ///
  /// This should be called when leaving full-screen experiences like
  /// the video player to restore the app's default orientation behavior.
  static void restoreDefaultOrientations(BuildContext context) {
    if (PlatformDetector.isAutomotive()) return;
    // Leaving a full-screen experience also gives rotation back to the system
    // lock, in case the player exited by a path that did not clear it.
    unawaited(setFollowSensorOrientation(false));
    final isPhone = PlatformDetector.isPhone(context);

    if (isPhone) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// Sets orientation to landscape-only mode.
  ///
  /// Used by the video player to force landscape orientation during playback.
  static void setLandscapeOrientation() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (PlatformDetector.isAutomotive()) return;
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  /// Restores the app's default visible system UI mode.
  ///
  /// Should be called when exiting full-screen mode.
  static Future<void> restoreSystemUI() async {
    // Explicitly show both overlays first to clear any legacy immersive flags.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
}
