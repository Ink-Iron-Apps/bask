import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/app_database.dart';
import '../utils/app_logger.dart';
import 'credential_vault.dart';
import 'sensitive_prefs.dart';

/// Thrown when a credential section cannot be opened with the passphrase
/// given. Indistinguishable, on purpose, from a tampered payload: AES-GCM
/// fails its MAC check either way, and telling the two apart would say which
/// of the two a caller got right.
class WrongPassphraseException implements Exception {
  const WrongPassphraseException();
  @override
  String toString() => 'WrongPassphraseException';
}

/// Thrown when a credential section is structurally unusable — a field
/// missing, a base64 value that will not decode, an unknown KDF.
class MalformedCredentialSectionException implements Exception {
  final String message;
  const MalformedCredentialSectionException(this.message);
  @override
  String toString() => 'MalformedCredentialSectionException: $message';
}

/// What an import put back.
class CredentialImportResult {
  final int prefsRestored;
  final int connectionsRestored;
  final int profileLinksRestored;

  const CredentialImportResult({
    required this.prefsRestored,
    required this.connectionsRestored,
    required this.profileLinksRestored,
  });

  bool get isEmpty => prefsRestored == 0 && connectionsRestored == 0 && profileLinksRestored == 0;
}

/// Passphrase encryption for the credential half of a settings export.
///
/// Separate from [CredentialVault], which protects credentials *at rest on one
/// device* with a key that lives in SharedPreferences beside them. That key is
/// deliberately not what guards an export: it never leaves the device, because
/// a file carrying it would both expose every ciphertext it protects and, on
/// import, risk overwriting the target's own key and orphaning the credentials
/// already stored there. An export is sealed with a key derived from a
/// passphrase the viewer types, and nothing else.
class CredentialExportEnvelope {
  CredentialExportEnvelope._();

  static const int version = 1;
  static const String kdfName = 'pbkdf2-hmac-sha256';

  /// PBKDF2-HMAC-SHA256 at OWASP's current floor. High enough to make a
  /// weak passphrase expensive to attack offline, low enough that a TV's CPU
  /// still opens the file in about a second.
  static const int iterations = 210000;
  static const int _saltBytes = 16;

  static final AesGcm _cipher = AesGcm.with256bits();
  static final Random _random = Random.secure();

  static Future<SecretKey> _deriveKey(String passphrase, List<int> salt) {
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
    return kdf.deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
  }

  static Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  /// Seals [payload] into the JSON object an export file carries.
  static Future<Map<String, Object?>> seal(Map<String, Object?> payload, String passphrase) async {
    final salt = _randomBytes(_saltBytes);
    final key = await _deriveKey(passphrase, salt);
    final box = await _cipher.encrypt(utf8.encode(jsonEncode(payload)), secretKey: key);
    return {
      'version': version,
      'kdf': kdfName,
      'iterations': iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  /// Opens a sealed section, or throws [WrongPassphraseException].
  static Future<Map<String, Object?>> open(Map<String, Object?> section, String passphrase) async {
    final sectionVersion = section['version'];
    if (sectionVersion is! int) throw const MalformedCredentialSectionException('Missing version');
    if (sectionVersion > version) {
      throw MalformedCredentialSectionException('Unsupported credential version: $sectionVersion');
    }
    if (section['kdf'] != kdfName) {
      throw MalformedCredentialSectionException('Unsupported kdf: ${section['kdf']}');
    }
    final iterationCount = section['iterations'];
    if (iterationCount is! int || iterationCount <= 0) {
      throw const MalformedCredentialSectionException('Missing iterations');
    }

    final List<int> salt;
    final List<int> nonce;
    final List<int> ciphertext;
    final List<int> mac;
    try {
      salt = base64Decode(section['salt']! as String);
      nonce = base64Decode(section['nonce']! as String);
      ciphertext = base64Decode(section['ciphertext']! as String);
      mac = base64Decode(section['mac']! as String);
    } catch (_) {
      throw const MalformedCredentialSectionException('Unreadable credential section');
    }

    // The file states its own cost so an export made at a future default
    // still opens, rather than failing as a wrong passphrase.
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterationCount, bits: 256);
    final key = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);

    final List<int> clear;
    try {
      clear = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
    } catch (_) {
      throw const WrongPassphraseException();
    }

    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map<String, dynamic>) {
      throw const MalformedCredentialSectionException('Credential payload is not an object');
    }
    return decoded;
  }
}

/// Gathers and restores the credentials a settings export can carry.
///
/// Three stores hold them: the sensitive SharedPreferences slots named by
/// [isSensitivePrefKey], the `connections` rows and the `profile_connections`
/// rows. Server and profile tokens sit in those rows [CredentialVault]-
/// protected, so they are revealed on the way out and re-protected with the
/// *target* device's key on the way in. The vault key itself is never carried.
class CredentialPortability {
  CredentialPortability._();

  static const String payloadVersionKey = 'payloadVersion';
  static const int payloadVersion = 1;

  /// Reads every credential this device can hand over, in clear text.
  ///
  /// The result is only ever passed to [CredentialExportEnvelope.seal]; it must
  /// not be written anywhere, logged, or returned to a caller that will not
  /// seal it.
  static Future<Map<String, Object?>> gather({
    required AppDatabase database,
    required SharedPreferencesWithCache prefs,
  }) async {
    final sensitive = <String, Object?>{};
    for (final key in prefs.keys) {
      // The vault key is the one credential that must stay behind: it is
      // meaningless on another install, and importing it would orphan every
      // ciphertext the target already holds.
      if (key == credentialVaultKeyPref) continue;
      if (!isSensitivePrefKey(key)) continue;
      final value = prefs.get(key);
      if (value is String) sensitive[key] = value;
    }

    final connections = <Map<String, Object?>>[];
    for (final row in await database.select(database.connections).get()) {
      connections.add({
        'id': row.id,
        'kind': row.kind,
        'displayName': row.displayName,
        'configJson': await _revealConfig(row.kind, row.configJson),
        'createdAt': row.createdAt,
        'lastAuthenticatedAt': row.lastAuthenticatedAt,
      });
    }

    final profileLinks = <Map<String, Object?>>[];
    for (final row in await database.select(database.profileConnections).get()) {
      profileLinks.add({
        'profileId': row.profileId,
        'connectionId': row.connectionId,
        'userToken': await CredentialVault.reveal(row.userToken) ?? '',
        'userIdentifier': row.userIdentifier,
        'isDefault': row.isDefault,
        'tokenAcquiredAt': row.tokenAcquiredAt,
        'lastUsedAt': row.lastUsedAt,
      });
    }

    return {
      payloadVersionKey: payloadVersion,
      'prefs': sensitive,
      'connections': connections,
      'profileConnections': profileLinks,
    };
  }

  /// Puts a gathered payload onto this device.
  ///
  /// Rows are written by primary key, so importing twice is the same as
  /// importing once, and a connection the target already has is replaced by
  /// the imported one rather than duplicated under a second id.
  static Future<CredentialImportResult> apply(
    Map<String, Object?> payload, {
    required AppDatabase database,
    required SharedPreferencesWithCache prefs,
  }) async {
    final declared = payload[payloadVersionKey];
    if (declared is! int) throw const MalformedCredentialSectionException('Missing payloadVersion');
    if (declared > payloadVersion) {
      throw MalformedCredentialSectionException('Unsupported credential payload: $declared');
    }

    var prefsRestored = 0;
    final rawPrefs = payload['prefs'];
    if (rawPrefs is Map) {
      for (final entry in rawPrefs.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        // A file claiming the vault key is either malformed or hostile; it is
        // the one key an import may never set.
        if (key == credentialVaultKeyPref || !isSensitivePrefKey(key) || value is! String) continue;
        await prefs.setString(key, value);
        prefsRestored++;
      }
    }

    var connectionsRestored = 0;
    final rawConnections = payload['connections'];
    if (rawConnections is List) {
      for (final raw in rawConnections) {
        if (raw is! Map) continue;
        final id = raw['id'];
        final kind = raw['kind'];
        final displayName = raw['displayName'];
        final configJson = raw['configJson'];
        final createdAt = raw['createdAt'];
        if (id is! String || kind is! String || displayName is! String || configJson is! String) continue;
        await database
            .into(database.connections)
            .insertOnConflictUpdate(
              ConnectionRow(
                id: id,
                kind: kind,
                displayName: displayName,
                configJson: await _protectConfig(kind, configJson),
                createdAt: createdAt is int ? createdAt : DateTime.now().millisecondsSinceEpoch,
                lastAuthenticatedAt: raw['lastAuthenticatedAt'] is int ? raw['lastAuthenticatedAt'] as int : null,
              ),
            );
        connectionsRestored++;
      }
    }

    var profileLinksRestored = 0;
    final rawLinks = payload['profileConnections'];
    if (rawLinks is List) {
      for (final raw in rawLinks) {
        if (raw is! Map) continue;
        final profileId = raw['profileId'];
        final connectionId = raw['connectionId'];
        final userIdentifier = raw['userIdentifier'];
        if (profileId is! String || connectionId is! String || userIdentifier is! String) continue;
        final token = raw['userToken'];
        await database
            .into(database.profileConnections)
            .insertOnConflictUpdate(
              ProfileConnectionRow(
                profileId: profileId,
                connectionId: connectionId,
                userToken: token is String && token.isNotEmpty ? await CredentialVault.protect(token) : '',
                userIdentifier: userIdentifier,
                isDefault: raw['isDefault'] == true,
                tokenAcquiredAt: raw['tokenAcquiredAt'] is int ? raw['tokenAcquiredAt'] as int : null,
                lastUsedAt: raw['lastUsedAt'] is int ? raw['lastUsedAt'] as int : null,
              ),
            );
        profileLinksRestored++;
      }
    }

    appLogger.i(
      'Credential import restored $prefsRestored preference(s), '
      '$connectionsRestored connection(s), $profileLinksRestored profile link(s)',
    );
    return CredentialImportResult(
      prefsRestored: prefsRestored,
      connectionsRestored: connectionsRestored,
      profileLinksRestored: profileLinksRestored,
    );
  }

  static Future<String> _revealConfig(String kind, String configJson) async {
    final decoded = jsonDecode(configJson);
    if (decoded is! Map<String, dynamic>) return configJson;
    return jsonEncode((await CredentialVault.revealConnectionConfig(kind, decoded)).config);
  }

  static Future<String> _protectConfig(String kind, String configJson) async {
    final decoded = jsonDecode(configJson);
    if (decoded is! Map<String, dynamic>) return configJson;
    return jsonEncode(await CredentialVault.protectConnectionConfig(kind, decoded));
  }
}
