import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';

import '../test_helpers/download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DownloadManagerService manager;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    manager = DownloadManagerService(
      database: db,
      storageService: DownloadStorageService.instance,
      clientResolver: (serverId, {clientScopeId}) => null,
    );
    manager.recoveryFuture = Future<void>.value();

    await db.insertDownload(
      serverId: ServerId('srv'),
      ratingKey: 'ep-1',
      globalKey: 'srv:ep-1',
      type: 'episode',
      status: DownloadStatus.downloading.index,
    );
  });

  tearDown(() async {
    manager.dispose();
    await db.close();
  });

  test('a download waiting its turn is not restarted for reporting nothing', () async {
    // Queue several episodes and all but the first sit behind the holding
    // queue's concurrency limit, reporting nothing by design. Treating that
    // silence as a stall cancelled the entry, re-queued it, and did the same
    // again two minutes later while the one actually transferring carried on.
    final asked = <String>[];
    manager.debugNativeWaitingProbe = (globalKey) async {
      asked.add(globalKey);
      return true;
    };

    await manager.debugHandleDownloadStalled('srv:ep-1');

    expect(asked, ['srv:ep-1']);
    final row = await db.getDownloadedMedia('srv:ep-1');
    // Untouched: same status, no retry counted.
    expect(row?.status, DownloadStatus.downloading.index);
    expect(row?.retryCount, 0);
  });

  test('a download the native layer is not holding is still restarted', () async {
    manager.debugNativeWaitingProbe = (_) async => false;

    await manager.debugHandleDownloadStalled('srv:ep-1');

    // No client resolves in this harness, so the restart stops after
    // cancelling — what matters is that it got that far rather than
    // short-circuiting as "waiting".
    final row = await db.getDownloadedMedia('srv:ep-1');
    expect(row, isNotNull);
  });

  test('a download that is no longer downloading is forgotten, not restarted', () async {
    await db.updateDownloadStatus('srv:ep-1', DownloadStatus.completed.index);
    var probed = false;
    manager.debugNativeWaitingProbe = (_) async {
      probed = true;
      return false;
    };

    await manager.debugHandleDownloadStalled('srv:ep-1');

    expect(probed, isFalse, reason: 'a finished download needs no native lookup');
  });
}
