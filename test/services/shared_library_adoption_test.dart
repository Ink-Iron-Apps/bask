import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:bask/database/app_database.dart';
import 'package:bask/database/download_operations.dart';
import 'package:bask/models/download_models.dart';
import 'package:bask/services/download_storage_service.dart';
import 'package:bask/services/settings_service.dart';
import 'package:bask/services/shared_library_adoption.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/prefs.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tmpRoot;
  late Directory library;
  late AppDatabase db;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    tmpRoot = await Directory.systemTemp.createTemp('bask_shared_library_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    library = Directory(p.join(tmpRoot.path, 'shared', 'Bask'));
    await Directory(p.join(library.path, 'downloads')).create(recursive: true);
    await Directory(p.join(library.path, 'artwork')).create(recursive: true);
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
  });

  SharedLibraryAdoptionService build() => SharedLibraryAdoptionService(libraryRoot: () async => library);

  Future<void> writeDescriptor(Map<String, Object?> body) =>
      File(p.join(library.path, SharedLibraryAdoptionService.descriptorName)).writeAsString(json.encode(body));

  Map<String, Object?> descriptorBody({int version = 1, int fileCount = 1, String? settingsFile, String? rowsFile}) => {
    'version': version,
    'writtenAt': '2026-11-18T10:04:51.629798Z',
    'downloadsFolder': 'downloads',
    'artworkFolder': 'artwork',
    'fileCount': fileCount,
    'settingsFile': ?settingsFile,
    'rowsFile': ?rowsFile,
  };

  Future<File> placeMedia(String relativePath, {int bytes = 8}) async {
    final file = File(p.join(library.path, 'downloads', p.joinAll(p.posix.split(relativePath))));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(bytes, 7));
    return file;
  }

  Future<void> writeRows(List<Map<String, Object?>> rows, {int version = 1, String? name}) {
    final file = File(p.join(library.path, name ?? SharedLibraryAdoptionService.defaultRowsFileName));
    return file.writeAsString(json.encode({'version': version, 'downloads': rows}));
  }

  Map<String, Object?> rowBody({
    String serverId = 'server-1',
    String ratingKey = '1001',
    String? globalKey,
    String type = 'movie',
    String videoFile = 'Movies/Arrival (2016)/Arrival (2016).mkv',
    String? thumbFile,
    int? totalBytes = 8,
  }) => {
    'serverId': serverId,
    'ratingKey': ratingKey,
    'globalKey': ?globalKey,
    'type': type,
    'videoFile': videoFile,
    'thumbFile': ?thumbFile,
    'totalBytes': totalBytes,
    'downloadedAt': 1700000000000,
    'mediaIndex': 0,
  };

  group('reading the descriptor', () {
    test('a complete descriptor names the folders it describes', () async {
      await writeDescriptor(descriptorBody(fileCount: 16, settingsFile: 'plezy-settings-auto-x.json'));

      final descriptor = await build().descriptor();

      expect(descriptor, isNotNull);
      expect(descriptor!.fileCount, 16);
      expect(descriptor.downloadsPath, p.join(library.path, 'downloads'));
      expect(descriptor.artworkPath, p.join(library.path, 'artwork'));
      expect(descriptor.settingsBackup?.path, p.join(library.path, 'plezy-settings-auto-x.json'));
      expect(descriptor.writtenAt, DateTime.utc(2026, 11, 18, 10, 4, 51, 629, 798));
      // Unnamed records fall back to the agreed filename rather than nothing,
      // so a writer that only writes the file is still understood.
      expect(descriptor.rows.path, p.join(library.path, SharedLibraryAdoptionService.defaultRowsFileName));
    });

    test('no descriptor means there is nothing to adopt', () async {
      expect(await build().descriptor(), isNull);
    });

    test('a version this build does not know is refused rather than guessed at', () async {
      await writeDescriptor(descriptorBody(version: 2));
      expect(await build().descriptor(), isNull);
    });

    test('a descriptor that is not JSON is refused', () async {
      await File(p.join(library.path, SharedLibraryAdoptionService.descriptorName)).writeAsString('{ not json');
      expect(await build().descriptor(), isNull);
    });

    test('a descriptor naming no downloads folder is refused', () async {
      final body = descriptorBody()..remove('downloadsFolder');
      await writeDescriptor(body);
      expect(await build().descriptor(), isNull);
    });
  });

  group('reading the records', () {
    test('a missing records file is no records, not a failure', () async {
      await writeDescriptor(descriptorBody());
      final descriptor = (await build().descriptor())!;
      expect(await build().readRows(descriptor), isEmpty);
    });

    test('records written at another version are ignored', () async {
      await writeDescriptor(descriptorBody());
      await writeRows([rowBody()], version: 99);
      final descriptor = (await build().descriptor())!;
      expect(await build().readRows(descriptor), isEmpty);
    });

    test('an entry missing what identifies it is dropped, and the rest are kept', () async {
      await writeDescriptor(descriptorBody());
      await writeRows([
        {'serverId': 'server-1', 'type': 'movie'},
        rowBody(ratingKey: '2002'),
      ]);
      final descriptor = (await build().descriptor())!;

      final rows = await build().readRows(descriptor);

      expect(rows.map((row) => row.ratingKey), ['2002']);
      // Derived, not demanded: the key is serverId:ratingKey by construction.
      expect(rows.single.globalKey, 'server-1:2002');
    });
  });

  group('importing the records', () {
    test('a record is rewritten to the folder the files are actually in', () async {
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv');
      await File(p.join(library.path, 'artwork', 'abc123.jpg')).writeAsBytes([1, 2]);
      await writeDescriptor(descriptorBody());
      await writeRows([rowBody(thumbFile: 'abc123.jpg')]);
      final descriptor = (await build().descriptor())!;

      expect(await build().importRows(descriptor: descriptor, database: db), 1);

      final row = (await db.allDownloadedMedia()).single;
      expect(row.globalKey, 'server-1:1001');
      expect(row.videoFilePath, p.join(library.path, 'downloads', 'Movies', 'Arrival (2016)', 'Arrival (2016).mkv'));
      expect(row.thumbPath, p.join(library.path, 'artwork', 'abc123.jpg'));
      expect(row.status, DownloadStatus.completed.index);
      expect(row.progress, 100);
      expect(row.safRootUri, isNull);
      // The writing install's profile scope would stop the active profile
      // ever claiming the row, so it is deliberately not carried across.
      expect(row.clientScopeId, isNull);
    });

    test('a size the writer never learned is measured from the file', () async {
      // Anchor: a download whose size was never learned is recorded as zero,
      // and no file in a finished library is genuinely zero bytes long. Taken
      // literally it would import as a download of nothing and display as
      // nothing, over a file that is sitting right there.
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv', bytes: 4096);
      await placeMedia('Movies/Dune (2021)/Dune (2021).mkv', bytes: 2048);
      await writeDescriptor(descriptorBody(fileCount: 2));
      await writeRows([
        rowBody(totalBytes: 0),
        rowBody(ratingKey: '2002', videoFile: 'Movies/Dune (2021)/Dune (2021).mkv', totalBytes: null),
      ]);
      final descriptor = (await build().descriptor())!;

      expect(await build().importRows(descriptor: descriptor, database: db), 2);

      final rows = {for (final row in await db.allDownloadedMedia()) row.ratingKey: row};
      expect(rows['1001']!.totalBytes, 4096);
      expect(rows['1001']!.downloadedBytes, 4096);
      expect(rows['2002']!.totalBytes, 2048);
      expect(rows['2002']!.downloadedBytes, 2048);
    });

    test('a size the writer does know is taken as given', () async {
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv', bytes: 8);
      await writeDescriptor(descriptorBody());
      // Deliberately unequal to the file on disk: a row that names a real size
      // is the authority, so a truncated or sparse copy is not quietly
      // re-measured into looking complete.
      await writeRows([rowBody(totalBytes: 2093775466)]);
      final descriptor = (await build().descriptor())!;

      await build().importRows(descriptor: descriptor, database: db);

      final row = (await db.allDownloadedMedia()).single;
      expect(row.totalBytes, 2093775466);
      expect(row.downloadedBytes, 2093775466);
    });

    test('a record whose file is not in the folder is not imported', () async {
      await writeDescriptor(descriptorBody());
      await writeRows([rowBody()]);
      final descriptor = (await build().descriptor())!;

      expect(await build().importRows(descriptor: descriptor, database: db), 0);
      expect(await db.allDownloadedMedia(), isEmpty);
    });

    test('artwork that did not travel is not invented', () async {
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv');
      await writeDescriptor(descriptorBody());
      await writeRows([rowBody(thumbFile: 'missing.jpg')]);
      final descriptor = (await build().descriptor())!;

      await build().importRows(descriptor: descriptor, database: db);

      expect((await db.allDownloadedMedia()).single.thumbPath, isNull);
    });

    test("this install's own row for the same item wins", () async {
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv');
      await db
          .into(db.downloadedMedia)
          .insert(
            DownloadedMediaCompanion.insert(
              serverId: 'server-1',
              ratingKey: '1001',
              globalKey: 'server-1:1001',
              type: 'movie',
              status: DownloadStatus.completed.index,
              videoFilePath: const Value('downloads/own-copy.mkv'),
            ),
          );
      await writeDescriptor(descriptorBody());
      await writeRows([rowBody()]);
      final descriptor = (await build().descriptor())!;

      expect(await build().importRows(descriptor: descriptor, database: db), 0);
      expect((await db.allDownloadedMedia()).single.videoFilePath, 'downloads/own-copy.mkv');
    });
  });

  group('reconciling the folder', () {
    test('a record pointing into the folder at nothing is dropped', () async {
      await writeDescriptor(descriptorBody());
      final descriptor = (await build().descriptor())!;
      await db
          .into(db.downloadedMedia)
          .insert(
            DownloadedMediaCompanion.insert(
              serverId: 'server-1',
              ratingKey: '1001',
              globalKey: 'server-1:1001',
              type: 'movie',
              status: DownloadStatus.completed.index,
              videoFilePath: Value(p.join(descriptor.downloadsPath, 'Movies', 'Gone.mkv')),
            ),
          );

      expect(await build().pruneUnplayableRows(descriptor: descriptor, database: db), 1);
      expect(await db.allDownloadedMedia(), isEmpty);
    });

    test("a record outside the folder is none of the adoption's business", () async {
      await writeDescriptor(descriptorBody());
      final descriptor = (await build().descriptor())!;
      await db
          .into(db.downloadedMedia)
          .insert(
            DownloadedMediaCompanion.insert(
              serverId: 'server-1',
              ratingKey: '1001',
              globalKey: 'server-1:1001',
              type: 'movie',
              status: DownloadStatus.completed.index,
              videoFilePath: const Value('downloads/app-private/Gone.mkv'),
            ),
          );

      expect(await build().pruneUnplayableRows(descriptor: descriptor, database: db), 0);
      expect(await db.allDownloadedMedia(), hasLength(1));
    });

    test('counting media ignores everything that is not a download', () async {
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv');
      await placeMedia('TV Shows/Show/Season 01/S01E01 - One.mkv');
      await placeMedia('TV Shows/Show/Season 01/S01E01 - One.srt');
      await placeMedia('TV Shows/Show/Season 01/S01E02 - Two.mkv.part');

      expect(await build().countMediaFiles(Directory(p.join(library.path, 'downloads'))), 2);
    });
  });

  group('adopting the folder', () {
    test('the folder becomes the download root and its files become playable', () async {
      final settings = await SettingsService.getInstance();
      await DownloadStorageService.instance.initialize(settings);
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv');
      await placeMedia('TV Shows/Show/Season 01/S01E01 - One.mkv');
      await writeDescriptor(descriptorBody(fileCount: 2));
      await writeRows([
        rowBody(),
        rowBody(ratingKey: '2002', type: 'episode', videoFile: 'TV Shows/Show/Season 01/S01E01 - One.mkv'),
      ]);
      final service = build();
      final descriptor = (await service.descriptor())!;

      final result = await service.adopt(descriptor: descriptor, database: db);

      expect(result.adoptedRoot, isTrue);
      expect(result.rowsImported, 2);
      expect(result.rowsPruned, 0);
      expect(result.filesOnDisk, 2);
      expect(result.filesClaimed, 2);
      expect(result.filesUnclaimed, 0);
      expect(result.isComplete, isTrue);
      expect(settings.read(SettingsService.customDownloadPath), descriptor.downloadsPath);
      expect(settings.read(SettingsService.customDownloadPathType), 'file');
      expect(service.isAlreadyAdopted(descriptor), isTrue);
      // Artwork is a refetchable cache. An empty artwork folder is the normal
      // outcome of a move whose rows carried no artwork path, and must never
      // read as a failed adoption.
      expect(Directory(descriptor.artworkPath).listSync(), isEmpty);
    });

    test('a folder with no records is adopted, and says so rather than claiming success', () async {
      final settings = await SettingsService.getInstance();
      await DownloadStorageService.instance.initialize(settings);
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv');
      await writeDescriptor(descriptorBody(fileCount: 1));
      final service = build();
      final descriptor = (await service.descriptor())!;

      final result = await service.adopt(descriptor: descriptor, database: db);

      expect(result.adoptedRoot, isTrue);
      expect(result.rowsImported, 0);
      expect(result.filesOnDisk, 1);
      expect(result.filesClaimed, 0);
      expect(result.filesUnclaimed, 1);
      expect(result.isComplete, isFalse);
    });

    test('a folder that cannot be written is left alone entirely', () async {
      // Anchor: records pointing into a folder the app cannot manage give a
      // library whose entries refuse to delete, so nothing is read from one.
      final settings = await SettingsService.getInstance();
      await DownloadStorageService.instance.initialize(settings);
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv');
      await writeDescriptor(descriptorBody(fileCount: 1));
      await writeRows([rowBody()]);
      final service = SharedLibraryAdoptionService(
        libraryRoot: () async => library,
        setDownloadLocation: (path, pathType) async =>
            throw DownloadStorageException('Download directory is not writable', path, StateError('Access denied')),
      );
      final descriptor = (await service.descriptor())!;

      final result = await service.adopt(descriptor: descriptor, database: db);

      expect(result.adoptedRoot, isFalse);
      expect(result.rowsImported, 0);
      expect(result.filesOnDisk, 1);
      expect(await db.allDownloadedMedia(), isEmpty);
      expect(settings.read(SettingsService.customDownloadPath), isNull);
    });

    test('records naming files that never arrived leave a library that can be played', () async {
      final settings = await SettingsService.getInstance();
      await DownloadStorageService.instance.initialize(settings);
      await placeMedia('Movies/Arrival (2016)/Arrival (2016).mkv');
      await writeDescriptor(descriptorBody(fileCount: 2));
      await writeRows([rowBody(), rowBody(ratingKey: '2002', videoFile: 'Movies/Dune (2021)/Dune (2021).mkv')]);
      final service = build();
      final descriptor = (await service.descriptor())!;

      final result = await service.adopt(descriptor: descriptor, database: db);

      expect(result.rowsImported, 1);
      expect(result.filesClaimed, 1);
      expect(result.expectedFileCount, 2);
      expect(result.isComplete, isFalse);
      expect((await db.allDownloadedMedia()).single.ratingKey, '1001');
    });
  });
}
