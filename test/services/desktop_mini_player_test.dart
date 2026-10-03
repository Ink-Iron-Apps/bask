import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/desktop_mini_player.dart';

void main() {
  tearDown(DesktopMiniPlayer.resetForTesting);

  test('offered exactly where there is no native picture-in-picture', () {
    // Android, iOS and macOS hand the app a real PiP window and should use
    // it; this mode exists for the platforms that have none.
    expect(DesktopMiniPlayer.isSupported, Platform.isWindows || Platform.isLinux);
  });

  test('starts inactive and ignores an exit it was never in', () async {
    // Exiting without entering must not restore geometry it never captured —
    // that would move a window the user placed themselves.
    expect(DesktopMiniPlayer.active.value, isFalse);

    await DesktopMiniPlayer.exit();

    expect(DesktopMiniPlayer.active.value, isFalse);
  });

  test('a window manager that refuses leaves the mode off', () async {
    // No window_manager plugin under test, so entering fails the same way a
    // refusing window manager would. The flag must not be left set: a
    // half-applied mode is worse than none, and the button would then offer
    // to leave a mode the user is not in.
    await DesktopMiniPlayer.enter();

    expect(DesktopMiniPlayer.active.value, isFalse);
  });
}
