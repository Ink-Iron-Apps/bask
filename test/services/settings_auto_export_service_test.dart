import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/services/settings_auto_export_service.dart';
import 'package:plezy/services/settings_export_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
  });

  SettingsAutoExportService build({
    required List<DateTime?> lastBackup,
    required List<String> writes,
    Duration debounce = const Duration(milliseconds: 10),
    Duration staleAfter = const Duration(hours: 24),
  }) {
    return SettingsAutoExportService(
      settings: settings,
      debounce: debounce,
      staleAfter: staleAfter,
      lastBackupAt: () async => lastBackup.isEmpty ? null : lastBackup.first,
      writeBackup: () async {
        writes.add('written');
        return '/tmp/backup.json';
      },
    );
  }

  group('when a backup is written', () {
    test('writes at startup when none has ever been taken', () async {
      final writes = <String>[];
      final service = build(lastBackup: [null], writes: writes);
      addTearDown(service.dispose);

      await service.start();

      expect(writes, hasLength(1));
    });

    test('writes at startup when the newest backup has gone stale', () async {
      final writes = <String>[];
      final service = build(lastBackup: [DateTime.now().subtract(const Duration(days: 3))], writes: writes);
      addTearDown(service.dispose);

      await service.start();

      expect(writes, hasLength(1));
    });

    test('leaves a fresh backup alone at startup', () async {
      final writes = <String>[];
      final service = build(lastBackup: [DateTime.now().subtract(const Duration(minutes: 5))], writes: writes);
      addTearDown(service.dispose);

      await service.start();

      expect(writes, isEmpty);
    });

    test('a burst of changes produces one write, not one per setting', () async {
      final writes = <String>[];
      final service = build(lastBackup: [DateTime.now()], writes: writes);
      addTearDown(service.dispose);
      await service.start();
      expect(writes, isEmpty);

      await settings.write(SettingsService.showUnwatchedCount, false);
      await settings.write(SettingsService.hideSpoilers, true);
      await settings.write(SettingsService.showNavBarLabels, false);
      await service.settled;

      expect(writes, hasLength(1));
    });

    test('nothing is written while the preference is off', () async {
      final writes = <String>[];
      await settings.write(SettingsService.autoExportSettings, false);
      final service = build(lastBackup: [null], writes: writes);
      addTearDown(service.dispose);

      await service.start();
      await settings.write(SettingsService.hideSpoilers, true);
      await service.settled;

      expect(writes, isEmpty);
    });

    test('a failing backup is swallowed rather than surfaced', () async {
      final service = SettingsAutoExportService(
        settings: settings,
        debounce: const Duration(milliseconds: 10),
        lastBackupAt: () async => null,
        writeBackup: () async => throw const FileSystemException('disk full'),
      );
      addTearDown(service.dispose);

      await expectLater(service.start(), completes);
    });

    test('disposing stops a pending write', () async {
      final writes = <String>[];
      final service = build(lastBackup: [DateTime.now()], writes: writes, debounce: const Duration(seconds: 5));
      await service.start();

      await settings.write(SettingsService.hideSpoilers, true);
      service.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(writes, isEmpty);
    });
  });

  group('what lands on disk', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('plezy_auto_export_test_');
      PathProviderPlatform.instance = FakePathProvider(root);
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('a backup carries settings and never a credential section', () async {
      await settings.write(SettingsService.hideSpoilers, true);

      final path = await SettingsExportService.writeAutomaticBackup();

      expect(path, isNotNull);
      final contents = await File(path!).readAsString();
      expect(contents, contains('hide_spoilers'));
      expect(contents, isNot(contains(SettingsExportService.credentialsKey)));
      expect(p.basename(path), startsWith(SettingsExportService.automaticFilePrefix));
    });

    test('rotation keeps the newest few and never touches a manual export', () async {
      final documents = Directory(p.join(root.path, 'documents'))..createSync(recursive: true);
      final manual = File(p.join(documents.path, 'plezy-settings-20260101.json'))..writeAsStringSync('{}');

      for (var i = 0; i < 5; i++) {
        await SettingsExportService.writeAutomaticBackup(keep: 3);
        // Distinct names and modification times, which a same-millisecond
        // loop would not produce.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final automatic = documents
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith(SettingsExportService.automaticFilePrefix))
          .toList();

      expect(automatic, hasLength(3));
      expect(manual.existsSync(), isTrue);
    });

    test('the newest automatic backup is the one reported', () async {
      await SettingsExportService.writeAutomaticBackup();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = await SettingsExportService.writeAutomaticBackup();

      final newest = await SettingsExportService.newestAutomaticBackup();

      expect(newest?.path, second);
    });
  });
}
