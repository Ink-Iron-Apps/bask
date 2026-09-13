import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/app_update_service.dart';

void main() {
  group('isNewerVersion', () {
    test('detects a newer release', () {
      expect(isNewerVersion(latest: '2.14.0', current: '2.13.0'), isTrue);
      expect(isNewerVersion(latest: '2.13.1', current: '2.13.0'), isTrue);
      expect(isNewerVersion(latest: '3.0.0', current: '2.99.99'), isTrue);
    });

    test('ignores same or older releases', () {
      expect(isNewerVersion(latest: '2.13.0', current: '2.13.0'), isFalse);
      expect(isNewerVersion(latest: '2.12.9', current: '2.13.0'), isFalse);
    });

    test('compares numerically, not lexically', () {
      // '10' sorts before '9' as text; a string compare would miss this update.
      expect(isNewerVersion(latest: '2.10.0', current: '2.9.0'), isTrue);
      expect(isNewerVersion(latest: '2.9.0', current: '2.10.0'), isFalse);
    });

    test('tolerates a leading v and differing component counts', () {
      expect(isNewerVersion(latest: 'v2.14.0', current: '2.13.0'), isTrue);
      expect(isNewerVersion(latest: '2.14', current: '2.13.9'), isTrue);
      expect(isNewerVersion(latest: '2.13', current: '2.13.0'), isFalse);
    });

    test('treats unparseable versions as no update', () {
      // Never offer an update we cannot reason about: a bad tag must not push
      // an arbitrary APK at the user.
      expect(isNewerVersion(latest: 'nightly', current: '2.13.0'), isFalse);
      expect(isNewerVersion(latest: '', current: '2.13.0'), isFalse);
    });
  });

  group('selectApkAsset', () {
    Map<String, dynamic> asset(String name) => {'name': name, 'url': 'https://api/$name'};

    test('prefers the ABI the device actually runs', () {
      final assets = [
        asset('Plexy-v2.14.0-armeabi-v7a.apk'),
        asset('Plexy-v2.14.0-arm64-v8a.apk'),
        asset('Plexy-v2.14.0-x86_64.apk'),
      ];

      expect(selectApkAsset(assets, abis: ['arm64-v8a', 'armeabi-v7a'])?['name'], 'Plexy-v2.14.0-arm64-v8a.apk');
      expect(selectApkAsset(assets, abis: ['x86_64'])?['name'], 'Plexy-v2.14.0-x86_64.apk');
    });

    test('honours the device ABI order', () {
      final assets = [asset('Plexy-arm64-v8a.apk'), asset('Plexy-armeabi-v7a.apk')];

      // A 32-bit-first device must not be handed the 64-bit build.
      expect(selectApkAsset(assets, abis: ['armeabi-v7a', 'arm64-v8a'])?['name'], 'Plexy-armeabi-v7a.apk');
    });

    test('does not hand a 32-bit x86 device the 64-bit build', () {
      // 'x86_64'.contains('x86') is true, so a substring match installs an APK
      // the device cannot run. Emulators are exactly where x86-only shows up.
      final assets = [asset('Plexy-v2.14.0-x86_64.apk'), asset('Plexy-v2.14.0-arm64-v8a.apk')];

      expect(selectApkAsset(assets, abis: ['x86']), isNull);
    });

    test('falls back to a universal APK when no ABI matches', () {
      final assets = [asset('Plexy-v2.14.0.apk'), asset('Plexy-v2.14.0-x86_64.apk')];

      expect(selectApkAsset(assets, abis: ['riscv64'])?['name'], 'Plexy-v2.14.0.apk');
    });

    test('fallback ABI order degrades safely when the device cannot be asked', () {
      // A 32-bit device cannot install the arm64 build, and finds out only
      // after downloading it. A 64-bit device runs the 32-bit build fine, so
      // the blind guess has to be armeabi-v7a first.
      final assets = [asset('Plexy-v2.23.0-arm64-v8a.apk'), asset('Plexy-v2.23.0-armeabi-v7a.apk')];

      expect(selectApkAsset(assets, abis: fallbackDeviceAbis)?['name'], 'Plexy-v2.23.0-armeabi-v7a.apk');
    });

    test('returns null when the release carries no APK', () {
      expect(selectApkAsset([asset('Plexy-sources.zip')], abis: ['arm64-v8a']), isNull);
      expect(selectApkAsset([], abis: ['arm64-v8a']), isNull);
    });
  });

  group('AvailableUpdate', () {
    test('notes default to empty so a release without a body still installs', () {
      const update = AvailableUpdate(version: '2.24.2', assetUrl: 'https://example/api', assetName: 'app.apk');
      expect(update.notes, isEmpty);
    });

    test('notes are carried verbatim for the install confirmation', () {
      const body = 'Fixes the thing.\n\n- one\n- two';
      const update = AvailableUpdate(
        version: '2.24.2',
        assetUrl: 'https://example/api',
        assetName: 'app.apk',
        notes: body,
      );
      expect(update.notes, body);
    });
  });
}
