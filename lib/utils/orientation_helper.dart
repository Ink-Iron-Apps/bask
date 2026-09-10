import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'app_logger.dart';
import 'platform_detector.dart';

class OrientationHelper {
  static const MethodChannel _deviceChannel = MethodChannel('com.plezy/device');

  /// Lets the player be held any way up, turning with the device.
  ///
  /// One writer only. [SystemChrome.setPreferredOrientations] and the native
  /// override both set the activity's requested orientation, so issuing both
  /// leaves the result to whichever platform message lands last — and Flutter's
  /// maps to FULL_USER, which obeys the rotation lock and undoes the override.
  /// On Android the native call already permits every orientation, so it is the
  /// only one made.
  static Future<void> allowAllOrientations() async {
    if (Platform.isAndroid) {
      await setFollowSensorOrientation(true);
      return;
    }
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

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

  /// Restores the app's default orientation preferences: every orientation
  /// on every handheld. Phones rotate into the landscape shell (leading
  /// navigation rail) like tablets do; the video player owns its own lock.
  ///
  /// This should be called when leaving full-screen experiences like
  /// the video player to restore the app's default orientation behavior.
  static Future<void> restoreDefaultOrientations() async {
    // Cars are fixed-orientation devices; asking would only pin a compact
    // head unit that reads as a phone.
    if (PlatformDetector.isAutomotive()) return;
    // Leaving a full-screen experience also gives rotation back to the system
    // lock, in case the player exited by a path that did not clear it.
    unawaited(setFollowSensorOrientation(false));
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
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
