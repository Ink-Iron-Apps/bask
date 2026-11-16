import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:bask/services/first_run_restore.dart';
import 'package:bask/services/settings_service.dart';
import 'package:bask/services/storage_service.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late StorageService storage;
  late Directory root;
  late Directory documents;

  final sessionStart = DateTime.now();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    storage = await StorageService.getInstance();
    root = await Directory.systemTemp.createTemp('plezy_first_run_restore_test_');
    documents = Directory(p.join(root.path, 'documents'))..createSync(recursive: true);
    PathProviderPlatform.instance = FakePathProvider(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> writeBackup({required DateTime modified, String name = 'plezy-settings-auto-old.json'}) async {
    final file = File(p.join(documents.path, name));
    await file.writeAsString('{"formatVersion": 1, "prefs": {}}');
    await file.setLastModified(modified);
    return file;
  }

  Future<void> signIn() async {
    await settings.prefs.setString('active_app_profile_id', 'profile-a');
  }

  test('offers a backup written before this session to a fresh signed-in install', () async {
    await signIn();
    final backup = await writeBackup(modified: sessionStart.subtract(const Duration(days: 2)));

    final candidate = await FirstRunRestore.candidate(settings: settings, storage: storage, sessionStart: sessionStart);

    expect(candidate?.path, backup.path);
  });

  test('offers nothing before anyone has signed in', () async {
    await writeBackup(modified: sessionStart.subtract(const Duration(days: 2)));

    final candidate = await FirstRunRestore.candidate(settings: settings, storage: storage, sessionStart: sessionStart);

    // An import re-scopes user-scoped keys and throws without an account, so
    // the offer waits rather than failing in front of the viewer.
    expect(candidate, isNull);
  });

  test('offers nothing once the question has been put', () async {
    await signIn();
    await writeBackup(modified: sessionStart.subtract(const Duration(days: 2)));
    await settings.write(SettingsService.restorePromptShown, true);

    expect(await FirstRunRestore.candidate(settings: settings, storage: storage, sessionStart: sessionStart), isNull);
  });

  test('offers nothing to an install that has been configured', () async {
    await signIn();
    await writeBackup(modified: sessionStart.subtract(const Duration(days: 2)));
    // One portable preference set by hand is enough to mean "this install has
    // settings of its own", which a restore must not quietly replace.
    await settings.write(SettingsService.hideSpoilers, true);

    expect(await FirstRunRestore.candidate(settings: settings, storage: storage, sessionStart: sessionStart), isNull);
  });

  test('ignores a backup this session wrote', () async {
    await signIn();
    // The automatic backup writes at startup when none exists, so on a fresh
    // install the newest file is a snapshot of the empty settings.
    await writeBackup(modified: sessionStart.add(const Duration(seconds: 5)), name: 'plezy-settings-auto-new.json');

    expect(await FirstRunRestore.candidate(settings: settings, storage: storage, sessionStart: sessionStart), isNull);
  });

  test('picks the newest backup older than this session', () async {
    await signIn();
    await writeBackup(modified: sessionStart.subtract(const Duration(days: 9)), name: 'plezy-settings-auto-a.json');
    final newer = await writeBackup(
      modified: sessionStart.subtract(const Duration(hours: 2)),
      name: 'plezy-settings-auto-b.json',
    );
    await writeBackup(modified: sessionStart.add(const Duration(seconds: 5)), name: 'plezy-settings-auto-c.json');

    final candidate = await FirstRunRestore.candidate(settings: settings, storage: storage, sessionStart: sessionStart);

    expect(candidate?.path, newer.path);
  });

  test('marking the offer recorded survives the next look', () async {
    await signIn();
    await writeBackup(modified: sessionStart.subtract(const Duration(days: 2)));

    await FirstRunRestore.markOffered(settings);

    expect(settings.read(SettingsService.restorePromptShown), isTrue);
    expect(await FirstRunRestore.candidate(settings: settings, storage: storage, sessionStart: sessionStart), isNull);
  });

  test('the prompt flag is not something an imported file can set', () {
    // Otherwise a backup could answer the question for the install that
    // restores it, and that install would never be asked again.
    expect(
      SettingsService.portablePrefs.map((pref) => pref.key),
      isNot(contains(SettingsService.restorePromptShown.key)),
    );
  });
}
