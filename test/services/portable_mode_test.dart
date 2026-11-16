import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:bask/services/portable_mode.dart';

void main() {
  setUp(PortableMode.resetForTesting);
  tearDown(PortableMode.resetForTesting);

  test('no marker means the app keeps its normal locations', () async {
    final dir = await Directory.systemTemp.createTemp('portable_off_');
    addTearDown(() => dir.delete(recursive: true));

    PortableMode.initialize(executablePathOverride: p.join(dir.path, 'bask.exe'), registerPlatform: false);

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

    PortableMode.initialize(executablePathOverride: p.join(dir.path, 'bask.exe'), registerPlatform: false);

    if (!Platform.isWindows) {
      // Only Windows can be portable; elsewhere the call is inert by design.
      expect(PortableMode.isActive, isFalse);
      expect(PortableMode.supportPath, isNull);
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

    // What the downloader's storage isolate is handed; it must be the same
    // folder the rest of the app uses, not a second one beside it.
    expect(PortableMode.supportPath, await paths.getApplicationSupportPath());
  });

  test('initialising twice does not re-detect', () {
    PortableMode.initialize(executablePathOverride: r'C:\nowhere\plexy.exe', registerPlatform: false);
    PortableMode.initialize(executablePathOverride: r'C:\nowhere\plexy.exe', registerPlatform: false);
    expect(PortableMode.isActive, isFalse);
  });

  test('a copy renamed from Plexy adopts the folder it already had', () async {
    // Anchor: a portable install has no package manager and no sandbox to
    // carry state across a rename. The folder beside the executable is the
    // whole install, so an in-place update must find the old one.
    final dir = await Directory.systemTemp.createTemp('portable_adopt_');
    addTearDown(() => dir.delete(recursive: true));
    File(p.join(dir.path, PortableMode.markerFileName)).writeAsStringSync('');
    final legacy = Directory(p.join(dir.path, PortableMode.legacyDataDirectoryName))..createSync();
    File(p.join(legacy.path, 'settings.json')).writeAsStringSync('{"kept":true}');

    PortableMode.initialize(executablePathOverride: p.join(dir.path, 'bask.exe'), registerPlatform: false);

    if (!Platform.isWindows) {
      expect(PortableMode.isActive, isFalse);
      return;
    }

    expect(PortableMode.root!.path, p.join(dir.path, PortableMode.dataDirectoryName));
    expect(
      File(p.join(PortableMode.root!.path, 'settings.json')).readAsStringSync(),
      '{"kept":true}',
      reason: 'the old folder has to arrive with its contents, not just its name',
    );
    expect(legacy.existsSync(), isFalse, reason: 'adoption is a move, so nothing is left to diverge');
  });

  test('an existing folder is never replaced by a leftover Plexy one', () async {
    // Anchor: running the old build once more after the new one must not be
    // able to overwrite newer state with older state.
    final dir = await Directory.systemTemp.createTemp('portable_no_clobber_');
    addTearDown(() => dir.delete(recursive: true));
    File(p.join(dir.path, PortableMode.markerFileName)).writeAsStringSync('');
    final current = Directory(p.join(dir.path, PortableMode.dataDirectoryName))..createSync();
    File(p.join(current.path, 'settings.json')).writeAsStringSync('{"current":true}');
    final legacy = Directory(p.join(dir.path, PortableMode.legacyDataDirectoryName))..createSync();
    File(p.join(legacy.path, 'settings.json')).writeAsStringSync('{"stale":true}');

    PortableMode.initialize(executablePathOverride: p.join(dir.path, 'bask.exe'), registerPlatform: false);

    if (!Platform.isWindows) {
      expect(PortableMode.isActive, isFalse);
      return;
    }

    expect(File(p.join(current.path, 'settings.json')).readAsStringSync(), '{"current":true}');
    expect(legacy.existsSync(), isTrue, reason: 'left alone rather than merged or deleted');
  });
}
