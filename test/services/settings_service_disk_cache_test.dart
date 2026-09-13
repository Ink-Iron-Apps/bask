import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);
  tearDown(TvDetectionService.debugReset);

  test('buffering to storage is off by default on a TV', () async {
    // Anchor: a TV's storage is small, often nearly full, and shared with the
    // cache directory Android reclaims when the volume fills — which cost this
    // app both playback smoothness and its subtitle fonts. Handhelds keep the
    // buffer; TVs must opt in.
    TvDetectionService.debugSetTvDeviceOverride(true);
    TvDetectionService.debugSetAppleTVOverride(true);
    expect(SettingsService.diskCacheSizeGB.resolvedDefault, 0);
  });

  test('handhelds keep buffering to storage by default', () async {
    expect(PlatformDetector.isTV(), isFalse);
    expect(SettingsService.diskCacheSizeGB.resolvedDefault, 4);
  });
}
