import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:bask/database/app_database.dart';
import 'package:bask/services/download_handoff_service.dart';
import 'package:bask/services/settings_handoff_service.dart';

void main() {
  // Two databases on purpose: a stand-in for the previous install's file and
  // this app's own. The warning is about accidental double construction.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory appDir;

  setUp(() async {
    appDir = await Directory.systemTemp.createTemp('bask_download_handoff_');
    SettingsHandoffService.debugSupportedOverride = true;
  });

  tearDown(() async {
    SettingsHandoffService.debugSupportedOverride = null;
    if (await appDir.exists()) await appDir.delete(recursive: true);
  });

  DownloadHandoffService build({
    Map<Object?, Object?>? manifest,
    List<String>? copyLog,
    Map<String, int>? sizes,
    bool failDatabaseCopy = false,
  }) {
    return DownloadHandoffService(
      appDirectory: () async => appDir,
      readManifest: (_) async => manifest,
      copyFile: ({required authority, required segment, required destination, relativePath}) async {
        copyLog?.add('$segment:${relativePath ?? ''}');
        if (segment == DownloadHandoffService.databaseSegment && failDatabaseCopy) {
          throw const FileSystemException('no database');
        }
        final bytes = sizes?[relativePath] ?? 4;
        final file = File(destination);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(List<int>.filled(bytes, 7));
        return bytes;
      },
    );
  }

  group('reading what the previous install holds', () {
    test('paths and sizes line up, and blanks are dropped', () async {
      final service = build(
        manifest: {
          'authority': 'com.inknironapps.plexy.settingshandoff',
          'paths': ['Show/S01E01.mkv', '', 'Film.mkv'],
          'sizes': [120, 999, 80],
          'databaseSize': 40,
        },
      );

      final manifest = await service.manifest();

      expect(manifest, isNotNull);
      expect(manifest!.entries.map((e) => e.relativePath), ['Show/S01E01.mkv', 'Film.mkv']);
      // The blank path's size is discarded with it rather than shifting the
      // remaining sizes along by one.
      expect(manifest.entries.map((e) => e.bytes), [120, 80]);
      expect(manifest.fileBytes, 200);
      expect(manifest.totalBytes, 240);
      expect(manifest.isEmpty, isFalse);
    });

    test('no previous install means nothing to offer', () async {
      expect(await build(manifest: null).manifest(), isNull);
    });

    test('a database with no files is still nothing to offer', () async {
      // Anchor: records describing files that are gone would show a library
      // full of downloads that cannot be played.
      final service = build(manifest: {'authority': 'a', 'paths': <String>[], 'sizes': <int>[], 'databaseSize': 4096});

      expect((await service.manifest())!.isEmpty, isTrue);
    });
  });

  group('copying the files', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('each file lands under the downloads folder', () async {
      final log = <String>[];
      final service = build(copyLog: log, sizes: {'Show/S01E01.mkv': 10});
      const manifest = DownloadHandoffManifest(
        authority: 'a',
        entries: [DownloadHandoffEntry(relativePath: 'Show/S01E01.mkv', bytes: 10)],
        databaseBytes: 0,
      );

      final result = await service.restore(manifest: manifest, database: db);

      expect(result.filesCopied, 1);
      expect(result.filesFailed, 0);
      expect(result.isComplete, isTrue);
      expect(File(p.join(appDir.path, 'downloads', 'Show', 'S01E01.mkv')).existsSync(), isTrue);
      expect(log, ['downloads:Show/S01E01.mkv']);
    });

    test('a file already here at the right size is left alone', () async {
      // Anchor: this is what makes an interrupted migration resumable rather
      // than a restart.
      final existing = File(p.join(appDir.path, 'downloads', 'Film.mkv'));
      await existing.parent.create(recursive: true);
      await existing.writeAsBytes(List<int>.filled(10, 1));

      final log = <String>[];
      final service = build(copyLog: log);
      const manifest = DownloadHandoffManifest(
        authority: 'a',
        entries: [DownloadHandoffEntry(relativePath: 'Film.mkv', bytes: 10)],
        databaseBytes: 0,
      );

      final result = await service.restore(manifest: manifest, database: db);

      expect(result.filesSkipped, 1);
      expect(result.filesCopied, 0);
      expect(log, isEmpty, reason: 'nothing should have been fetched');
    });

    test('a half-copied file is fetched again rather than trusted', () async {
      final partial = File(p.join(appDir.path, 'downloads', 'Film.mkv'));
      await partial.parent.create(recursive: true);
      await partial.writeAsBytes(List<int>.filled(3, 1));

      final service = build(sizes: {'Film.mkv': 10});
      const manifest = DownloadHandoffManifest(
        authority: 'a',
        entries: [DownloadHandoffEntry(relativePath: 'Film.mkv', bytes: 10)],
        databaseBytes: 0,
      );

      final result = await service.restore(manifest: manifest, database: db);

      expect(result.filesCopied, 1);
      expect(result.filesSkipped, 0);
      expect(await partial.length(), 10);
    });

    test('progress counts bytes, including the ones it skipped', () async {
      final existing = File(p.join(appDir.path, 'downloads', 'a.mkv'));
      await existing.parent.create(recursive: true);
      await existing.writeAsBytes(List<int>.filled(50, 1));

      final seen = <double>[];
      final service = build(sizes: {'b.mkv': 50});
      const manifest = DownloadHandoffManifest(
        authority: 'a',
        entries: [
          DownloadHandoffEntry(relativePath: 'a.mkv', bytes: 50),
          DownloadHandoffEntry(relativePath: 'b.mkv', bytes: 50),
        ],
        databaseBytes: 0,
      );

      await service.restore(manifest: manifest, database: db, onProgress: (p) => seen.add(p.fraction));

      expect(seen.first, 0);
      expect(seen.last, 1);
    });

    test('cancelling stops between files and writes no records', () async {
      final log = <String>[];
      final service = build(copyLog: log, manifest: null);
      const manifest = DownloadHandoffManifest(
        authority: 'a',
        entries: [
          DownloadHandoffEntry(relativePath: 'a.mkv', bytes: 4),
          DownloadHandoffEntry(relativePath: 'b.mkv', bytes: 4),
        ],
        databaseBytes: 4096,
      );

      final result = await service.restore(manifest: manifest, database: db, isCancelled: () => log.isNotEmpty);

      expect(result.cancelled, isTrue);
      expect(result.filesCopied, 1);
      expect(result.rowsImported, 0, reason: 'the database is only touched once the files are all here');
      expect(log.where((e) => e.startsWith('database')), isEmpty);
    });

    test('a failed file is counted and the rest still come over', () async {
      final service = DownloadHandoffService(
        appDirectory: () async => appDir,
        readManifest: (_) async => null,
        copyFile: ({required authority, required segment, required destination, relativePath}) async {
          if (relativePath == 'bad.mkv') throw const FileSystemException('unreadable');
          final file = File(destination);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(List<int>.filled(4, 7));
          return 4;
        },
      );
      const manifest = DownloadHandoffManifest(
        authority: 'a',
        entries: [
          DownloadHandoffEntry(relativePath: 'bad.mkv', bytes: 4),
          DownloadHandoffEntry(relativePath: 'good.mkv', bytes: 4),
        ],
        databaseBytes: 0,
      );

      final result = await service.restore(manifest: manifest, database: db);

      expect(result.filesFailed, 1);
      expect(result.filesCopied, 1);
      expect(result.isComplete, isFalse);
      expect(File(p.join(appDir.path, 'downloads', 'good.mkv')).existsSync(), isTrue);
    });

    test('the staged database is removed even when the import fails', () async {
      // Anchor: that staged file is a whole app database, credentials and all.
      // It must not outlive the import, successful or not.
      final service = build(failDatabaseCopy: true);
      const manifest = DownloadHandoffManifest(
        authority: 'a',
        entries: [DownloadHandoffEntry(relativePath: 'a.mkv', bytes: 4)],
        databaseBytes: 4096,
      );

      await service.restore(manifest: manifest, database: db);

      expect(File(p.join(appDir.path, DownloadHandoffService.stagedDatabaseName)).existsSync(), isFalse);
    });
  });

  group('importing the records', () {
    late AppDatabase target;
    late Directory legacyDir;
    late File legacyFile;

    Future<void> seedLegacy(List<Map<String, Object?>> rows) async {
      final legacy = AppDatabase.forTesting(NativeDatabase(legacyFile));
      for (final row in rows) {
        final columns = row.keys.join(', ');
        final values = row.values
            .map((v) => v == null ? 'NULL' : (v is String ? "'${v.replaceAll("'", "''")}'" : '$v'))
            .join(', ');
        await legacy.customStatement('INSERT INTO downloaded_media ($columns) VALUES ($values)');
      }
      await legacy.close();
    }

    setUp(() async {
      target = AppDatabase.forTesting(NativeDatabase.memory());
      legacyDir = await Directory.systemTemp.createTemp('bask_legacy_db_');
      legacyFile = File(p.join(legacyDir.path, 'plezy_downloads.db'));
    });

    tearDown(() async {
      await target.close();
      if (await legacyDir.exists()) await legacyDir.delete(recursive: true);
    });

    test('an absolute path from the old sandbox becomes relative', () async {
      // Anchor: the stored path names /data/data/com.inknironapps.plexy/...,
      // a directory this app cannot reach. Kept verbatim the row is useless.
      await seedLegacy([
        {
          'server_id': 'srv',
          'rating_key': '1',
          'global_key': 'srv:1',
          'type': 'movie',
          'status': 3,
          'video_file_path': '/data/data/com.inknironapps.plexy/app_flutter/downloads/Film.mkv',
          'thumb_path': '/data/data/com.inknironapps.plexy/app_flutter/downloads/Film.jpg',
        },
      ]);

      final imported = await DownloadHandoffService(
        appDirectory: () async => appDir,
        readManifest: (_) async => null,
        copyFile: ({required authority, required segment, required destination, relativePath}) async => 0,
      ).importRecords(database: target, legacyDatabase: legacyFile);

      expect(imported, 1);
      final row = await target.customSelect('SELECT video_file_path, thumb_path FROM downloaded_media').getSingle();
      expect(row.read<String>('video_file_path'), 'downloads/Film.mkv');
      expect(row.read<String>('thumb_path'), 'downloads/Film.jpg');
    });

    test('a row pointing at a SAF tree is left behind', () async {
      // Anchor: that permission was granted to the old package and cannot be
      // transferred, so the file is not ours to claim.
      await seedLegacy([
        {
          'server_id': 'srv',
          'rating_key': '2',
          'global_key': 'srv:2',
          'type': 'movie',
          'status': 3,
          'video_file_path': 'Film.mkv',
          'saf_root_uri': 'content://com.android.externalstorage.documents/tree/primary%3AMovies',
        },
      ]);

      final imported = await DownloadHandoffService(
        appDirectory: () async => appDir,
        readManifest: (_) async => null,
        copyFile: ({required authority, required segment, required destination, relativePath}) async => 0,
      ).importRecords(database: target, legacyDatabase: legacyFile);

      expect(imported, 0);
    });

    test('a record whose file never arrived is dropped again', () async {
      await seedLegacy([
        {
          'server_id': 'srv',
          'rating_key': '3',
          'global_key': 'srv:3',
          'type': 'movie',
          'status': 3,
          'video_file_path': 'downloads/Here.mkv',
        },
        {
          'server_id': 'srv',
          'rating_key': '4',
          'global_key': 'srv:4',
          'type': 'movie',
          'status': 3,
          'video_file_path': 'downloads/Missing.mkv',
        },
      ]);
      final present = File(p.join(appDir.path, 'downloads', 'Here.mkv'));
      await present.parent.create(recursive: true);
      await present.writeAsString('x');

      final service = DownloadHandoffService(
        appDirectory: () async => appDir,
        readManifest: (_) async => null,
        copyFile: ({required authority, required segment, required destination, relativePath}) async => 0,
      );
      await service.importRecords(database: target, legacyDatabase: legacyFile);
      final pruned = await service.pruneUnplayableRecords(database: target, appDirectory: appDir);

      expect(pruned, 1);
      final keys = await target.customSelect('SELECT global_key FROM downloaded_media').get();
      expect(keys.map((r) => r.read<String>('global_key')), ['srv:3']);
    });
  });
}
