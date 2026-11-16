import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/sensitive_prefs.dart';
import 'package:plezy/services/settings_credential_export.dart';

import '../test_helpers/prefs.dart';

/// A real 32-byte key: the vault base64-decodes this slot and rejects
/// anything shorter.
final String _testVaultKey = base64Encode(List<int>.generate(32, (i) => i));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.invalidateCache();
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  group('the sealed envelope', () {
    test('a payload survives a round trip through the passphrase', () async {
      final sealed = await CredentialExportEnvelope.seal({'token': 'secret-value'}, 'correct horse battery');

      expect(sealed['kdf'], CredentialExportEnvelope.kdfName);
      // The point of the exercise: nothing readable is left in the file.
      expect(jsonEncode(sealed), isNot(contains('secret-value')));

      final opened = await CredentialExportEnvelope.open(sealed, 'correct horse battery');
      expect(opened['token'], 'secret-value');
    });

    test('the wrong passphrase is refused rather than returning rubbish', () async {
      final sealed = await CredentialExportEnvelope.seal({'token': 'secret-value'}, 'right one');

      await expectLater(CredentialExportEnvelope.open(sealed, 'wrong one'), throwsA(isA<WrongPassphraseException>()));
    });

    test('a tampered ciphertext fails the same way a wrong passphrase does', () async {
      final sealed = await CredentialExportEnvelope.seal({'token': 'secret-value'}, 'passphrase');
      final bytes = base64Decode(sealed['ciphertext']! as String);
      bytes[0] = bytes[0] ^ 0xFF;
      sealed['ciphertext'] = base64Encode(bytes);

      await expectLater(CredentialExportEnvelope.open(sealed, 'passphrase'), throwsA(isA<WrongPassphraseException>()));
    });

    test('a file that states its own cost opens at that cost', () async {
      final sealed = await CredentialExportEnvelope.seal({'token': 'secret-value'}, 'passphrase');
      // A future default must not strand files written at today's.
      expect(sealed['iterations'], CredentialExportEnvelope.iterations);
      expect((await CredentialExportEnvelope.open(sealed, 'passphrase'))['token'], 'secret-value');
    });

    test('an unknown kdf is malformed, not a wrong passphrase', () async {
      final sealed = await CredentialExportEnvelope.seal({'token': 'x'}, 'passphrase');
      sealed['kdf'] = 'scrypt';

      await expectLater(
        CredentialExportEnvelope.open(sealed, 'passphrase'),
        throwsA(isA<MalformedCredentialSectionException>()),
      );
    });
  });

  group('gathering credentials', () {
    test('carries tracker sessions and connections but never the vault key', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(credentialVaultKeyPref, _testVaultKey);
      await prefs.setString('trakt_session', 'trakt-token');
      await prefs.setString('enable_hdr_unrelated', 'not a credential');

      await database
          .into(database.connections)
          .insert(
            ConnectionRow(
              id: 'conn-1',
              kind: 'jellyfin',
              displayName: 'Home',
              configJson: jsonEncode({
                'baseUrl': 'http://host:8096',
                'accessToken': await CredentialVault.protect('abc'),
              }),
              createdAt: 1700000000000,
              lastAuthenticatedAt: null,
            ),
          );

      final payload = await CredentialPortability.gather(database: database, prefs: prefs);

      final carriedPrefs = payload['prefs']! as Map<String, Object?>;
      expect(carriedPrefs['trakt_session'], 'trakt-token');
      // Device-local, and importing it would orphan the target's own
      // ciphertexts.
      expect(carriedPrefs.containsKey(credentialVaultKeyPref), isFalse);
      expect(carriedPrefs.containsKey('enable_hdr_unrelated'), isFalse);

      final connections = payload['connections']! as List;
      expect(connections, hasLength(1));
      final config = jsonDecode((connections.single as Map)['configJson'] as String) as Map<String, dynamic>;
      // Revealed on the way out: the export's own crypto protects it, not the
      // key that never leaves the device.
      expect(config['accessToken'], 'abc');
      expect(CredentialVault.isProtected(config['accessToken'] as String), isFalse);
    });
  });

  group('applying credentials', () {
    test('restores rows re-protected with this device key, and is idempotent', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final payload = {
        CredentialPortability.payloadVersionKey: CredentialPortability.payloadVersion,
        'prefs': {'mal_session': 'mal-token'},
        'connections': [
          {
            'id': 'conn-1',
            'kind': 'jellyfin',
            'displayName': 'Home',
            'configJson': jsonEncode({'baseUrl': 'http://host:8096', 'accessToken': 'plain-token'}),
            'createdAt': 1700000000000,
            'lastAuthenticatedAt': null,
          },
        ],
        'profileConnections': [
          {
            'profileId': 'profile-a',
            'connectionId': 'conn-1',
            'userToken': 'user-token',
            'userIdentifier': 'user-1',
            'isDefault': true,
            'tokenAcquiredAt': null,
            'lastUsedAt': null,
          },
        ],
      };

      final first = await CredentialPortability.apply(payload, database: database, prefs: prefs);
      expect(first.prefsRestored, 1);
      expect(first.connectionsRestored, 1);
      expect(first.profileLinksRestored, 1);
      expect(prefs.getString('mal_session'), 'mal-token');

      final stored = await database.select(database.connections).getSingle();
      final storedConfig = jsonDecode(stored.configJson) as Map<String, dynamic>;
      // Back under this device's key, not left in clear text.
      expect(CredentialVault.isProtected(storedConfig['accessToken'] as String), isTrue);
      expect(await CredentialVault.reveal(storedConfig['accessToken'] as String), 'plain-token');

      final link = await database.select(database.profileConnections).getSingle();
      expect(await CredentialVault.reveal(link.userToken), 'user-token');

      // Importing the same file twice writes the same rows, not duplicates.
      await CredentialPortability.apply(payload, database: database, prefs: prefs);
      expect(await database.select(database.connections).get(), hasLength(1));
      expect(await database.select(database.profileConnections).get(), hasLength(1));
    });

    test('refuses to set the vault key even when a file carries one', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(credentialVaultKeyPref, _testVaultKey);

      await CredentialPortability.apply(
        {
          CredentialPortability.payloadVersionKey: CredentialPortability.payloadVersion,
          'prefs': {credentialVaultKeyPref: 'attacker-key', 'trakt_session': 'ok'},
        },
        database: database,
        prefs: prefs,
      );

      expect(prefs.getString(credentialVaultKeyPref), _testVaultKey);
      expect(prefs.getString('trakt_session'), 'ok');
    });

    test('a payload from a newer app is refused rather than half-applied', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();

      await expectLater(
        CredentialPortability.apply(
          {
            CredentialPortability.payloadVersionKey: CredentialPortability.payloadVersion + 1,
            'prefs': {'trakt_session': 'nope'},
          },
          database: database,
          prefs: prefs,
        ),
        throwsA(isA<MalformedCredentialSectionException>()),
      );
      expect(prefs.getString('trakt_session'), isNull);
    });
  });
}
