import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/services/portable_mode.dart';

void main() {
  setUp(PortableMode.resetForTesting);
  tearDown(PortableMode.resetForTesting);

  test('no marker means the app keeps its normal locations', () async {
    final dir = await Directory.systemTemp.createTemp('portable_off_');
    addTearDown(() => dir.delete(recursive: true));

    PortableMode.initialize(executablePathOverride: p.join(dir.path, 'plexy.exe'), registerPlatform: false);

    expect(PortableMode.isActive, isFalse);
    expect(
      Directory(p.join(dir.path, 'data')).existsSync(),
      isFalse,
      reason: 'must not create state it was not asked for',
    );
  });

  test('a marker puts every writable location under the program folder', () async {
    // Anchor: a portable copy is one you can delete by deleting the folder.
    // That is only true if the database, preferences, caches and downloads
    // all land here rather than in %APPDATA%.
    final dir = await Directory.systemTemp.createTemp('portable_on_');
    addTearDown(() => dir.delete(recursive: true));
    File(p.join(dir.path, PortableMode.markerFileName)).writeAsStringSync('');

    PortableMode.initialize(executablePathOverride: p.join(dir.path, 'plexy.exe'), registerPlatform: false);

    if (!Platform.isWindows) {
      // Only Windows can be portable; elsewhere the call is inert by design.
      expect(PortableMode.isActive, isFalse);
      return;
    }

    expect(PortableMode.isActive, isTrue);
    expect(PortableMode.root!.path, p.join(dir.path, PortableMode.dataDirectoryName));

    final paths = PortablePathProvider(PortableMode.root!.path);
    for (final resolved in [
      await paths.getApplicationSupportPath(),
      await paths.getApplicationDocumentsPath(),
      await paths.getTemporaryPath(),
      await paths.getDownloadsPath(),
    ]) {
      expect(resolved, isNotNull);
      expect(p.isWithin(dir.path, resolved!), isTrue, reason: '$resolved escaped the program folder');
    }
  });

  test('initialising twice does not re-detect', () {
    PortableMode.initialize(executablePathOverride: r'C:\nowhere\plexy.exe', registerPlatform: false);
    PortableMode.initialize(executablePathOverride: r'C:\nowhere\plexy.exe', registerPlatform: false);
    expect(PortableMode.isActive, isFalse);
  });
}
