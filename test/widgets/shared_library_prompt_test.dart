import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:bask/database/app_database.dart';
import 'package:bask/database/download_operations.dart';
import 'package:bask/i18n/strings.g.dart';
import 'package:bask/services/settings_service.dart';
import 'package:bask/services/shared_library_adoption.dart';
import 'package:bask/services/shared_storage_service.dart';
import 'package:bask/widgets/shared_library_prompt.dart';

import '../test_helpers/prefs.dart';

/// What the offer decides before and around an adoption: whether the device
/// can have one, whether the permission has to be asked for first, whether
/// there is anything in the folder, and whether declining leaves it alone.
///
/// The folder is handed in rather than read from disk, and the adoption itself
/// is not exercised here: both are real file and database work, which does not
/// complete inside the fake async a widget test runs in. They are covered in
/// `test/services/shared_library_adoption_test.dart` instead.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late BuildContext host;
  late List<String> calls;
  late bool granted;

  const channel = MethodChannel('com.plezy/shared_storage_test');

  final folder = Directory(p.join(p.separator, 'storage', 'emulated', '0', 'Bask'));

  setUp(() async {
    // The offer asks the settings whether the folder is already this
    // install's download root, so the real service has to be standing.
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    calls = [];
    granted = true;
    SharedStorageService.debugSupportedOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'getSharedRoot' => p.dirname(folder.path),
        'hasAccess' => granted,
        'canRequestAccess' => true,
        'requestAccess' => true,
        _ => null,
      };
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    SharedStorageService.debugSupportedOverride = null;
    await db.close();
    SettingsService.resetForTesting();
  });

  SharedStorageService storage() => SharedStorageService(channel: channel);

  SharedLibraryDescriptor descriptor({int fileCount = 16}) => SharedLibraryDescriptor(
    root: folder,
    version: 1,
    downloadsFolder: 'downloads',
    artworkFolder: 'artwork',
    fileCount: fileCount,
  );

  SharedLibraryAdoptionService service(SharedLibraryDescriptor? found) =>
      SharedLibraryAdoptionService(libraryRoot: () async => folder, readDescriptor: () async => found);

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
  ({List<SharedLibraryAdoptionResult?> finished}) start(
    SharedLibraryDescriptor? found, {
    bool announceNothing = false,
    VoidCallback? onPermissionPending,
  }) {
    final finished = <SharedLibraryAdoptionResult?>[];
    unawaited(
      offerSharedLibraryAdoption(
        host,
        database: db,
        service: service(found),
        storage: storage(),
        announceNothing: announceNothing,
        onPermissionPending: onPermissionPending,
      ).then(finished.add),
    );
    return (finished: finished);
  }

  testWidgets('an empty folder is announced when the viewer asked', (tester) async {
    await pumpHost(tester);
    final run = start(null, announceNothing: true);
    await tester.pumpAndSettle();

    expect(run.finished, [null]);
    expect(find.text(t.settings.adoptLibraryNothing), findsOneWidget);
  });

  testWidgets('an empty folder says nothing when the app asked itself', (tester) async {
    // Anchor: startup runs this on a fresh install, and a device that never
    // had a library moved onto it must not be told about one.
    await pumpHost(tester);
    final run = start(null);
    await tester.pumpAndSettle();

    expect(run.finished, [null]);
    expect(find.text(t.settings.adoptLibraryNothing), findsNothing);
  });

  testWidgets('the permission is explained before the settings screen opens', (tester) async {
    // Android grants all-files access on its own screen, so the folder cannot
    // even be read — let alone described — until the viewer has been there.
    granted = false;
    await pumpHost(tester);
    var pending = false;
    final run = start(descriptor(), onPermissionPending: () => pending = true);
    await tester.pumpAndSettle();

    expect(find.text(t.settings.adoptLibraryPermissionTitle), findsOneWidget);
    expect(calls, isNot(contains('requestAccess')));

    await tester.tap(find.text(t.settings.adoptLibraryPermissionConfirm));
    await tester.pumpAndSettle();

    expect(calls, contains('requestAccess'));
    expect(run.finished, [null]);
    expect(find.text(t.settings.adoptLibraryPermissionMissing), findsOneWidget);
    // They said yes and left for the Settings screen, so the question is not
    // spent: by the next launch the permission is usually held.
    expect(pending, isTrue);
  });

  testWidgets('declining the permission asks for nothing', (tester) async {
    granted = false;
    await pumpHost(tester);
    var pending = false;
    final run = start(descriptor(), onPermissionPending: () => pending = true);
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.settings.restoreBackupDecline));
    await tester.pumpAndSettle();

    expect(run.finished, [null]);
    expect(calls, isNot(contains('requestAccess')));
    // A decline is an answer, so it stays answered.
    expect(pending, isFalse);
  });

  testWidgets('the offer names what is in the folder, and declining adopts nothing', (tester) async {
    await pumpHost(tester);
    final run = start(descriptor(fileCount: 16));
    await tester.pumpAndSettle();

    expect(find.text(t.settings.adoptLibraryFoundTitle), findsOneWidget);
    expect(
      find.textContaining(p.join(folder.path, 'downloads')),
      findsOneWidget,
      reason: 'the folder is the one thing the viewer cannot guess',
    );
    expect(find.textContaining('16'), findsOneWidget);

    await tester.tap(find.text(t.settings.adoptLibraryDecline));
    await tester.pumpAndSettle();

    expect(run.finished, [null]);
    expect(await db.allDownloadedMedia(), isEmpty);
  });
}
