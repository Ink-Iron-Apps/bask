import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bask/database/app_database.dart';
import 'package:bask/i18n/strings.g.dart';
import 'package:bask/services/download_handoff_service.dart';
import 'package:bask/services/settings_handoff_service.dart';
import 'package:bask/widgets/settings_restore_prompt.dart';

/// What the offer decides before and around a copy: whether there is anything
/// to offer, whether to say so, and whether a decline leaves the files alone.
///
/// The copy itself is not exercised here. It is real file and database work,
/// which does not run inside `testWidgets`' fake async, so it is covered in
/// `test/services/download_handoff_service_test.dart` instead.
void main() {
  // The stand-in for the previous install's database plus this app's own.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory appDir;
  late AppDatabase db;
  late BuildContext host;

  setUp(() async {
    appDir = await Directory.systemTemp.createTemp('bask_offer_downloads_');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SettingsHandoffService.debugSupportedOverride = true;
  });

  tearDown(() async {
    SettingsHandoffService.debugSupportedOverride = null;
    await db.close();
    if (await appDir.exists()) await appDir.delete(recursive: true);
  });

  DownloadHandoffService build({Map<Object?, Object?>? manifest}) {
    return DownloadHandoffService(
      appDirectory: () async => appDir,
      readManifest: (_) async => manifest,
      copyFile: ({required authority, required segment, required destination, relativePath}) async {
        final file = File(destination);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(const [7, 7, 7, 7]);
        return 4;
      },
    );
  }

  Map<Object?, Object?> oneFile() => {
    'authority': 'com.inknironapps.plexy.settingshandoff',
    'paths': ['Show/S01E01.mkv'],
    'sizes': [4],
    'databaseSize': 0,
  };

  File copiedFile() => File('${appDir.path}/downloads/Show/S01E01.mkv');

  Future<void> pumpHost(WidgetTester tester) {
    return tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                host = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Starts the offer without awaiting it, so the test can answer the dialogs
  /// it raises. The returned record reports back once it finishes.
  ({List<DownloadHandoffResult?> finished}) start(DownloadHandoffService service, {bool announceNothing = false}) {
    final finished = <DownloadHandoffResult?>[];
    unawaited(
      offerDownloadHandoff(host, database: db, service: service, announceNothing: announceNothing).then(finished.add),
    );
    return (finished: finished);
  }

  testWidgets('an empty predecessor is announced when the viewer asked', (tester) async {
    await pumpHost(tester);
    final run = start(build(manifest: null), announceNothing: true);
    await tester.pumpAndSettle();

    expect(run.finished, [null]);
    expect(find.text(t.settings.restoreDownloadsNothing), findsOneWidget);
  });

  testWidgets('an empty predecessor says nothing when the app asked itself', (tester) async {
    // Anchor: startup runs this until it is answered, and a device that never
    // had the old app must not be told about it on every launch.
    await pumpHost(tester);
    final run = start(build(manifest: null));
    await tester.pumpAndSettle();

    expect(run.finished, [null]);
    expect(find.text(t.settings.restoreDownloadsNothing), findsNothing);
  });

  testWidgets('declining copies nothing', (tester) async {
    await pumpHost(tester);
    final run = start(build(manifest: oneFile()));
    await tester.pumpAndSettle();

    expect(find.text(t.settings.restoreDownloadsFoundTitle), findsOneWidget);
    await tester.tap(find.text(t.settings.restoreDownloadsDecline));
    await tester.pumpAndSettle();

    expect(run.finished, [null]);
    expect(copiedFile().existsSync(), isFalse);
  });
}
