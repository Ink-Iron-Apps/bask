import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:bask/database/app_database.dart';
import 'package:bask/database/download_operations.dart';
import 'package:bask/media/ids.dart';
import 'package:bask/models/download_models.dart';
import 'package:bask/services/download_manager_service.dart';
import 'package:bask/services/download_storage_service.dart';
import 'package:bask/utils/platform_detector.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/download_fixtures.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmpRoot;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    resetSharedPreferencesForTest();
    DownloadStorageService.resetForTesting();
    tmpRoot = await Directory.systemTemp.createTemp('plexy-reclaim-test');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    PathProviderPlatform.instance = previousPathProvider;
    DownloadStorageService.resetForTesting();
    TvDetectionService.debugSetTvDeviceOverride(null);
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  DownloadManagerService managerFor() {
    final manager = DownloadManagerService(
      database: db,
      storageService: DownloadStorageService.instance,
      clientResolver: (serverId, {clientScopeId}) => null,
    );
    manager.recoveryFuture = Future<void>.value();
    addTearDown(manager.dispose);
    return manager;
  }

  test('a device that cannot download gives back the files it is still holding', () async {
    // A TV downloaded freely before downloads were gated off it. The Downloads
    // tab is gone, every manager operation short-circuits, and on a 4 GB data
    // partition those files are the difference between a working set-top box
    // and one that cannot buffer.
    TvDetectionService.debugSetTvDeviceOverride(true);

    final downloads = await DownloadStorageService.instance.getDownloadsDirectory();
    final video = File('${downloads.path}/stranded.mkv');
    await video.writeAsBytes(List<int>.filled(4096, 7));
    // Something the rows never named: a partial transfer or a sidecar.
    final orphan = File('${downloads.path}/leftover.part');
    await orphan.writeAsBytes(List<int>.filled(2048, 3));

    await db.insertDownload(
      serverId: ServerId('srv'),
      ratingKey: 'ep-1',
      globalKey: 'srv:ep-1',
      type: 'episode',
      status: DownloadStatus.completed.index,
    );
    await db.updateVideoFilePath('srv:ep-1', video.path);

    // The engine's own downloadsSupported stays true here on purpose: it is
    // false only on a tvOS build, while an Android TV keeps a working engine
    // and loses only the UI. The sweep follows the UI.
    final manager = managerFor();
    expect(PlatformDetector.supportsDownloads(), isFalse);

    final reclaimed = await manager.reclaimUnsupportedDownloads();

    expect(reclaimed, greaterThanOrEqualTo(4096 + 2048));
    expect(video.existsSync(), isFalse);
    expect(orphan.existsSync(), isFalse);
    expect(await db.getDownloadedMedia('srv:ep-1'), isNull);
  });

  test('a device that can download is left entirely alone', () async {
    TvDetectionService.debugSetTvDeviceOverride(false);

    final downloads = await DownloadStorageService.instance.getDownloadsDirectory();
    final video = File('${downloads.path}/keep.mkv');
    await video.writeAsBytes(List<int>.filled(1024, 1));

    await db.insertDownload(
      serverId: ServerId('srv'),
      ratingKey: 'ep-2',
      globalKey: 'srv:ep-2',
      type: 'episode',
      status: DownloadStatus.completed.index,
    );
    await db.updateVideoFilePath('srv:ep-2', video.path);

    final reclaimed = await managerFor().reclaimUnsupportedDownloads();

    expect(reclaimed, 0);
    expect(video.existsSync(), isTrue);
    expect(await db.getDownloadedMedia('srv:ep-2'), isNotNull);
  });
}
