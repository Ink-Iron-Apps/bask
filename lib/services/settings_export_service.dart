import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/app_database.dart';
import '../models/shader_preset.dart';
import '../i18n/strings.g.dart';
import '../utils/app_logger.dart';
import '../utils/formatters.dart';
import '../utils/platform_detector.dart';
import 'file_picker_service.dart';
import 'settings_credential_export.dart';
import 'settings_service.dart';
import 'storage_service.dart';

/// An export file sitting in the app's own documents directory, which is
/// where [SettingsExportService.exportToFile] leaves one on a TV.
class LocalExportFile {
  final String path;
  final String fileName;
  final DateTime modified;

  const LocalExportFile({required this.path, required this.fileName, required this.modified});
}

class ImportResult {
  final int keysImported;
  final int keysSkipped;

  /// What the credential section restored, or null when the file had none or
  /// no passphrase was supplied for it.
  final CredentialImportResult? credentials;

  /// The file carried credentials that were left alone, because no passphrase
  /// was offered. The UI says so rather than reporting a clean import.
  final bool credentialsSkipped;

  const ImportResult({
    required this.keysImported,
    required this.keysSkipped,
    this.credentials,
    this.credentialsSkipped = false,
  });
}

class SettingsExportException implements Exception {
  final String message;
  const SettingsExportException(this.message);
  @override
  String toString() => 'SettingsExportException: $message';
}

/// Thrown when an import is attempted without an active Plex user, since the
/// user prefix needed to re-scope library preferences is unavailable.
class NoUserSignedInException extends SettingsExportException {
  const NoUserSignedInException() : super('No user is signed in');
}

/// Thrown when the chosen file isn't a valid Plezy settings export.
class InvalidExportFileException extends SettingsExportException {
  const InvalidExportFileException(super.message);
}

class _PreferencePolicy {
  final String type;
  final bool userScoped;

  const _PreferencePolicy(this.type, {this.userScoped = false});
}

class _PendingImport {
  final String targetKey;
  final String type;
  final Object? value;
  final String? obsoleteKey;

  const _PendingImport({required this.targetKey, required this.type, required this.value, this.obsoleteKey});
}

class _StoredPreferenceValue {
  final bool existed;
  final Object? value;

  const _StoredPreferenceValue({required this.existed, required this.value});
}

/// Serializes / restores user-facing SharedPreferences to a JSON file.
///
/// Only preferences in the closed portable registry are exported. User-scoped
/// keys (prefixed with `user_{uuid}_`) have that prefix stripped on export and
/// re-applied with the current user's prefix on import, so preferences follow
/// whichever account is signed in on the target device.
class SettingsExportService {
  static const int formatVersion = 1;
  static const String fileExtension = 'json';

  /// Key of the optional passphrase-encrypted credential section.
  ///
  /// Its absence is the normal case: an export is settings only unless the
  /// viewer asked for sign-ins and typed a passphrase. A file that has it is
  /// a credential file and should be treated like one.
  static const String credentialsKey = 'credentials';

  // Type markers written into the export JSON. One per SharedPreferences setter.
  static const String _typeBool = 'bool';
  static const String _typeInt = 'int';
  static const String _typeDouble = 'double';
  static const String _typeString = 'string';
  static const String _typeStringList = 'stringList';
  static const String _userPrefixRoot = 'user_';
  // Device-local storage state must never cross installations. Keep these as
  // exact keys so portable download behavior settings remain transferable.
  static const Set<String> _nonPortableDeviceStorageKeys = {
    'custom_download_path',
    'custom_download_path_type',
    // Resolved per form factor, and wrong when carried across one. Buffering
    // to storage is off on a TV because its partition is small and shared
    // with the cache Android reclaims; the download limit is sized to the
    // device it was set on. Importing a phone's answers onto a TV reinstates
    // exactly the configuration that cost this app a debugging session.
    'disk_cache_size_gb',
    'download_storage_budget_gb',
  };
  static const String _tvosDatabaseRecoveryPrefix = 'tvos_db_recovery_';

  /// Closed registry of portable, user-facing settings, keyed by preference
  /// key. [SettingsService.portablePrefs] is the source of truth for membership
  /// and the [Pref] declarations for the stored types; credentials, runtime
  /// state, device paths, history, endpoints, and user-authored player
  /// configuration are intentionally absent.
  static final Map<String, _PreferencePolicy> _portablePreferences = {
    for (final pref in SettingsService.portablePrefs) pref.key: _PreferencePolicy(_storageTypeFor(pref)),
  };

  static final Map<String, String> _obsoleteSkipMarkerKeys = {
    for (final entry in SettingsService.legacySkipMarkerPrefs.entries) entry.value.key: entry.key,
  };

  static const Set<String> _jsonStringListPreferenceKeys = {'hidden_libraries', 'library_order'};

  static const Map<String, _PreferencePolicy> _userScopedPreferences = {
    'hidden_libraries': _PreferencePolicy(_typeString, userScoped: true),
    'library_filters': _PreferencePolicy(_typeString, userScoped: true),
    'library_order': _PreferencePolicy(_typeString, userScoped: true),
  };

  static final List<(RegExp, _PreferencePolicy)> _dynamicUserScopedPreferences = [
    (RegExp(r'^library_(?:filters|sort|grouping|tab)_.+$'), const _PreferencePolicy(_typeString, userScoped: true)),
  ];

  @visibleForTesting
  static FutureOr<void> Function(String key)? debugBeforeImportWrite;

  static String _storageTypeFor(Pref<Object?> pref) {
    if (pref is BoolPref) return _typeBool;
    if (pref is IntPref) return _typeInt;
    if (pref is DoublePref) return _typeDouble;
    if (pref is StringPref ||
        pref is NullableStringPref ||
        pref is EnumPref ||
        pref is NullableEnumPref ||
        pref is JsonPref) {
      return _typeString;
    }
    if (pref is StringListPref) return _typeStringList;

    if (pref.key == SettingsService.appLocale.key) return _typeString;
    if (pref.key == SettingsService.libraryDensity.key) return _typeInt;
    if (pref.key == SettingsService.automotiveUiScale.key) return _typeDouble;
    if (pref.key == SettingsService.autoPip.key ||
        pref.key == SettingsService.useExternalPlayer.key ||
        pref.key == SettingsService.audioPassthrough.key) {
      return _typeBool;
    }
    throw StateError('Portable preference ${pref.key} has no storage type');
  }

  static _PreferencePolicy? _policyFor(String baseKey) {
    if (baseKey.startsWith(_tvosDatabaseRecoveryPrefix)) return null;
    if (_nonPortableDeviceStorageKeys.contains(baseKey)) return null;
    final exact = _portablePreferences[baseKey] ?? _userScopedPreferences[baseKey];
    if (exact != null) return exact;
    for (final (pattern, policy) in _dynamicUserScopedPreferences) {
      if (pattern.hasMatch(baseKey)) return policy;
    }
    return null;
  }

  /// Builds the export map from the given prefs. Pure and testable.
  ///
  /// [currentUserUuid] — if set, keys prefixed with `user_{uuid}_` have that
  /// prefix stripped so they can be re-scoped on import. Keys belonging to any
  /// OTHER user are skipped (we only export the active user's prefs).
  static Map<String, dynamic> buildExportMap(
    SharedPreferencesWithCache prefs, {
    String? currentUserUuid,
    String appVersion = '',
  }) {
    final prefsOut = <String, Map<String, dynamic>>{};
    final currentUserPrefix = (currentUserUuid != null && currentUserUuid.isNotEmpty)
        ? '$_userPrefixRoot${currentUserUuid}_'
        : null;

    for (final fullKey in prefs.keys) {
      final bool sourceIsUserScoped;
      final String baseKey;
      if (currentUserPrefix != null && fullKey.startsWith(currentUserPrefix)) {
        sourceIsUserScoped = true;
        baseKey = fullKey.substring(currentUserPrefix.length);
      } else if (fullKey.startsWith(_userPrefixRoot)) {
        continue;
      } else {
        sourceIsUserScoped = false;
        baseKey = fullKey;
      }

      final policy = _policyFor(baseKey);
      if (policy == null || policy.userScoped != sourceIsUserScoped) continue;

      final entry = _encodeValue(_portableExportValue(baseKey, prefs.get(fullKey)), policy.type);
      if (entry != null) prefsOut[baseKey] = entry;
    }

    // A snapshot must preserve cold-upgrade choices without mutating storage
    // or depending on which typed preferences have been read by the UI.
    for (final entry in SettingsService.legacySkipMarkerPrefs.entries) {
      final pref = entry.value;
      if (prefs.containsKey(pref.key)) continue;
      final legacyValue = prefs.get(entry.key);
      if (legacyValue is bool) {
        prefsOut[pref.key] = {'type': _typeString, 'value': pref.fromLegacy(legacyValue).name};
      }
    }

    return {
      'formatVersion': formatVersion,
      'appVersion': appVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
      'prefs': prefsOut,
    };
  }

  static Object? _portableExportValue(String baseKey, Object? value) {
    if (baseKey != SettingsService.globalShaderPreset.key) return value;
    return value is String && ShaderPreset.fromId(value) != null ? value : ShaderPreset.none.id;
  }

  static Map<String, dynamic>? _encodeValue(Object? value, String expectedType) {
    return switch (expectedType) {
      _typeBool when value is bool => {'type': _typeBool, 'value': value},
      _typeInt when value is int => {'type': _typeInt, 'value': value},
      _typeDouble when value is double => {'type': _typeDouble, 'value': value},
      _typeString when value is String => {'type': _typeString, 'value': value},
      _typeStringList when _isValidValue(_typeStringList, value) => {
        'type': _typeStringList,
        'value': (value! as List).cast<String>().toList(),
      },
      _ => null,
    };
  }

  /// Applies a parsed export map to [prefs]. Pure and testable.
  ///
  /// Each logical preference in the import replaces its target value, retiring
  /// any obsolete representation. Omitted preferences are left alone. If both
  /// representations occur, the canonical entry wins regardless of entry order;
  /// an invalid canonical entry is skipped rather than replaced by a legacy one.
  ///
  /// Throws [SettingsExportException] for structural problems.
  static Future<ImportResult> applyImportMap(
    Map<String, dynamic> data,
    SharedPreferencesWithCache prefs, {
    required String currentUserUuid,
  }) async {
    final version = data['formatVersion'];
    if (version is! int) {
      throw const InvalidExportFileException('Missing formatVersion');
    }
    if (version > formatVersion) {
      throw InvalidExportFileException('Unsupported formatVersion: $version');
    }

    final rawPrefs = data['prefs'];
    if (rawPrefs is! Map) {
      throw const InvalidExportFileException('Missing prefs object');
    }

    final userPrefix = 'user_${currentUserUuid}_';
    final pending = <_PendingImport>[];
    int skipped = 0;

    for (final entry in rawPrefs.entries) {
      var baseKey = entry.key.toString();
      final rawEntry = entry.value;
      if (rawEntry is! Map) {
        skipped++;
        continue;
      }

      var type = rawEntry['type'];
      var value = rawEntry['value'];
      final legacyPref = SettingsService.legacySkipMarkerPrefs[baseKey];
      if (version == 1 && legacyPref != null) {
        if (rawPrefs.containsKey(legacyPref.key)) {
          skipped++;
          continue;
        }
        if (type == _typeBool && value is bool) {
          baseKey = legacyPref.key;
          type = _typeString;
          value = legacyPref.fromLegacy(value).name;
        }
      }

      final policy = _policyFor(baseKey);
      if (policy == null) {
        skipped++;
        continue;
      }
      // Early format-v1 exports described these JSON-backed values as native
      // string lists. Normalize that narrowly admitted legacy shape to the
      // String representation consumed by StorageService.
      if (version == 1 &&
          _jsonStringListPreferenceKeys.contains(baseKey) &&
          type == _typeStringList &&
          _isValidValue(_typeStringList, value)) {
        type = _typeString;
        value = jsonEncode((value as List).cast<String>());
      }
      if (type is! String || type != policy.type || !_isValidValue(type, value)) {
        skipped++;
        continue;
      }
      if (baseKey == SettingsService.globalShaderPreset.key && value is String && ShaderPreset.fromId(value) == null) {
        skipped++;
        continue;
      }

      pending.add(
        _PendingImport(
          targetKey: policy.userScoped ? '$userPrefix$baseKey' : baseKey,
          type: type,
          value: value,
          obsoleteKey: _obsoleteSkipMarkerKeys[baseKey],
        ),
      );
    }

    final snapshots = <String, _StoredPreferenceValue>{};
    for (final mutation in pending) {
      snapshots[mutation.targetKey] = _StoredPreferenceValue(
        existed: prefs.containsKey(mutation.targetKey),
        value: prefs.get(mutation.targetKey),
      );
      if (mutation.obsoleteKey case final obsoleteKey?) {
        snapshots[obsoleteKey] = _StoredPreferenceValue(
          existed: prefs.containsKey(obsoleteKey),
          value: prefs.get(obsoleteKey),
        );
      }
    }

    try {
      for (final mutation in pending) {
        await debugBeforeImportWrite?.call(mutation.targetKey);
        await _writeTyped(prefs, mutation.targetKey, mutation.type, mutation.value);
        if (mutation.obsoleteKey case final obsoleteKey?) {
          await debugBeforeImportWrite?.call(obsoleteKey);
          await prefs.remove(obsoleteKey);
        }
      }
    } catch (error, stackTrace) {
      try {
        await _restoreSnapshots(prefs, snapshots);
      } catch (rollbackError, rollbackStackTrace) {
        appLogger.e('Settings import rollback failed', error: rollbackError, stackTrace: rollbackStackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    return ImportResult(keysImported: pending.length, keysSkipped: skipped);
  }

  static bool _isValidValue(String type, Object? value) {
    return switch (type) {
      _typeBool => value is bool,
      _typeInt => value is int,
      _typeDouble => value is num,
      _typeString => value is String,
      _typeStringList => value is List && value.every((element) => element is String),
      _ => false,
    };
  }

  static Future<void> _writeTyped(SharedPreferencesWithCache prefs, String key, String type, Object? value) async {
    switch (type) {
      case _typeBool:
        await prefs.setBool(key, value! as bool);
      case _typeInt:
        await prefs.setInt(key, value! as int);
      case _typeDouble:
        await prefs.setDouble(key, (value! as num).toDouble());
      case _typeString:
        await prefs.setString(key, value! as String);
      case _typeStringList:
        await prefs.setStringList(key, (value! as List).cast<String>());
      default:
        throw StateError('Unsupported portable preference type');
    }
  }

  static Future<void> _restoreSnapshots(
    SharedPreferencesWithCache prefs,
    Map<String, _StoredPreferenceValue> snapshots,
  ) async {
    for (final entry in snapshots.entries) {
      final snapshot = entry.value;
      if (!snapshot.existed) {
        await prefs.remove(entry.key);
        continue;
      }
      switch (snapshot.value) {
        case final bool value:
          await prefs.setBool(entry.key, value);
        case final int value:
          await prefs.setInt(entry.key, value);
        case final double value:
          await prefs.setDouble(entry.key, value);
        case final String value:
          await prefs.setString(entry.key, value);
        case final List<Object?> value:
          await prefs.setStringList(entry.key, value.cast<String>());
        default:
          throw StateError('Unsupported stored preference type');
      }
    }
  }

  static Future<String> _defaultFileName() async {
    final now = DateTime.now();
    final y = padNumber(now.year, 4);
    final m = padNumber(now.month, 2);
    final d = padNumber(now.day, 2);
    return 'plezy-settings-$y$m$d.$fileExtension';
  }

  /// Serializes the current user's settings and writes them to a location of
  /// the user's choosing. Returns the saved path, or `null` if the user
  /// cancelled the picker.
  ///
  /// Platform and filesystem failures retain their original exception types.
  /// Writes an export file and returns where it landed.
  ///
  /// [credentialPassphrase] and [database] together add the credential
  /// section; either alone exports settings only. Nothing is encrypted with a
  /// passphrase the viewer did not type, and a settings-only file stays safe
  /// to pass around.
  static Future<String?> exportToFile({AppDatabase? database, String? credentialPassphrase}) async {
    final prefs = (await SettingsService.getInstance()).prefs;
    final storage = await StorageService.getInstance();
    String appVersion = '';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
    } on PlatformException {
      // Best-effort metadata; platforms without PackageInfo still export.
    }

    final exportMap = buildExportMap(prefs, currentUserUuid: storage.activeUserScope(), appVersion: appVersion);
    if (database != null && credentialPassphrase != null && credentialPassphrase.isNotEmpty) {
      final payload = await CredentialPortability.gather(database: database, prefs: prefs);
      exportMap[credentialsKey] = await CredentialExportEnvelope.seal(payload, credentialPassphrase);
    }
    final jsonString = const JsonEncoder.withIndent('  ').convert(exportMap);
    final bytes = Uint8List.fromList(utf8.encode(jsonString));
    final fileName = await _defaultFileName();

    // Android TV has no document picker — write to the app docs dir and let
    // the caller surface the path.
    if (usesLocalExportDirectory) {
      return _writeToAppDocuments(fileName, bytes);
    }

    return FilePickerService.instance.saveFile(
      dialogTitle: t.settings.exportDialogTitle,
      fileName: fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const [fileExtension],
    );
  }

  static Future<String> _writeToAppDocuments(String fileName, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Prompts the user to pick a settings JSON and writes its contents into
  /// SharedPreferences. Requires a signed-in user.
  ///
  /// Returns `null` if the user cancelled. Malformed files throw
  /// [InvalidExportFileException]; platform and filesystem failures retain
  /// their original exception types.
  static Future<ImportResult?> importFromFile({
    AppDatabase? database,
    Future<String?> Function()? passphraseProvider,
  }) async {
    final storage = await StorageService.getInstance();
    final uuid = storage.activeUserScope();
    if (uuid == null || uuid.isEmpty) {
      throw const NoUserSignedInException();
    }

    final picked = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [fileExtension],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return null;

    final file = picked.files.first;
    String contents;
    final bytes = file.bytes;
    if (bytes != null) {
      try {
        contents = utf8.decode(bytes);
      } on FormatException {
        throw const InvalidExportFileException('Could not read the selected file');
      }
    } else if (file.path != null) {
      contents = await File(file.path!).readAsString();
    } else {
      throw const InvalidExportFileException('Could not read the selected file');
    }

    return _applyImportContents(contents, uuid, database: database, passphraseProvider: passphraseProvider);
  }

  /// Imports an export already on disk, for platforms with no document picker.
  ///
  /// Android TV is the case: [exportToFile] drops the file in the app's own
  /// documents directory there because the picker does not exist, and without
  /// this the file it wrote could never be read back on the same device.
  static Future<ImportResult?> importFromPath(
    String path, {
    AppDatabase? database,
    Future<String?> Function()? passphraseProvider,
  }) async {
    final storage = await StorageService.getInstance();
    final uuid = storage.activeUserScope();
    if (uuid == null || uuid.isEmpty) {
      throw const NoUserSignedInException();
    }

    final String contents;
    try {
      contents = await File(path).readAsString();
    } on FileSystemException {
      throw const InvalidExportFileException('Could not read the selected file');
    } on FormatException {
      throw const InvalidExportFileException('Could not read the selected file');
    }
    return _applyImportContents(contents, uuid, database: database, passphraseProvider: passphraseProvider);
  }

  /// Imports an export held in memory rather than on disk.
  ///
  /// The settings handoff is why this exists: a predecessor app returns its
  /// export over a method channel, and there is no file to point at.
  static Future<ImportResult?> importFromJson(
    String contents, {
    AppDatabase? database,
    Future<String?> Function()? passphraseProvider,
  }) async {
    final storage = await StorageService.getInstance();
    final uuid = storage.activeUserScope();
    if (uuid == null || uuid.isEmpty) {
      throw const NoUserSignedInException();
    }
    return _applyImportContents(contents, uuid, database: database, passphraseProvider: passphraseProvider);
  }

  static Future<ImportResult> _applyImportContents(
    String contents,
    String uuid, {
    AppDatabase? database,
    Future<String?> Function()? passphraseProvider,
  }) async {
    final Object? decoded;
    try {
      decoded = json.decode(contents);
    } on FormatException {
      throw const InvalidExportFileException('Invalid export file');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const InvalidExportFileException('Invalid export file');
    }

    final prefs = (await SettingsService.getInstance()).prefs;
    final settings = await applyImportMap(decoded, prefs, currentUserUuid: uuid);

    final section = decoded[credentialsKey];
    if (section is! Map<String, dynamic>) return settings;

    ImportResult withoutCredentials() =>
        ImportResult(keysImported: settings.keysImported, keysSkipped: settings.keysSkipped, credentialsSkipped: true);

    if (database == null || passphraseProvider == null) return withoutCredentials();

    // Asked for only once the settings have landed, so a cancelled passphrase
    // still leaves the half of the import that needed no secret.
    final passphrase = await passphraseProvider();
    if (passphrase == null || passphrase.isEmpty) return withoutCredentials();

    final payload = await CredentialExportEnvelope.open(section, passphrase);
    final restored = await CredentialPortability.apply(payload, database: database, prefs: prefs);
    return ImportResult(keysImported: settings.keysImported, keysSkipped: settings.keysSkipped, credentials: restored);
  }

  /// Name prefix for a backup the app wrote by itself.
  ///
  /// Distinct from a manual export's name so rotation only ever deletes the
  /// app's own files: a viewer who exported to this directory on a TV keeps
  /// that file forever.
  static const String automaticFilePrefix = 'plezy-settings-auto-';

  /// Writes a settings-only backup into the app's documents directory and
  /// prunes older automatic ones, keeping [keep].
  ///
  /// Settings only, always: a backup nobody asked for must never be a
  /// credential file, and there is no passphrase to protect one with when
  /// the app is writing it unattended.
  static Future<String?> writeAutomaticBackup({int keep = 3}) async {
    final prefs = (await SettingsService.getInstance()).prefs;
    final storage = await StorageService.getInstance();
    final exportMap = buildExportMap(prefs, currentUserUuid: storage.activeUserScope(), appVersion: '');
    final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(exportMap)));

    final Directory dir;
    try {
      dir = await getApplicationDocumentsDirectory();
    } on MissingPlatformDirectoryException {
      return null;
    }

    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file = File(p.join(dir.path, '$automaticFilePrefix$stamp.$fileExtension'));
    await file.writeAsBytes(bytes, flush: true);
    await _pruneAutomaticBackups(keep: keep, dir: dir);
    return file.path;
  }

  static Future<void> _pruneAutomaticBackups({required int keep, required Directory dir}) async {
    final automatic = <File>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (!p.basename(entity.path).startsWith(automaticFilePrefix)) continue;
      automatic.add(entity);
    }
    if (automatic.length <= keep) return;
    automatic.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final stale in automatic.skip(keep)) {
      try {
        await stale.delete();
      } on FileSystemException catch (error) {
        // A backup that will not delete is not worth failing a backup over.
        appLogger.w('Could not prune an old settings backup', error: error);
      }
    }
  }

  /// The newest automatic backup, or null when none has been written.
  static Future<LocalExportFile?> newestAutomaticBackup() async {
    final all = await listLocalExports();
    for (final candidate in all) {
      if (candidate.fileName.startsWith(automaticFilePrefix)) return candidate;
    }
    return null;
  }

  /// Export files in the app's documents directory, newest first.
  ///
  /// The directory a TV export writes to, and the only place a TV can read
  /// one back from. Copying a file there over adb, or from another install
  /// of the app, is how an export crosses devices without a picker.
  static Future<List<LocalExportFile>> listLocalExports() async {
    final Directory dir;
    try {
      dir = await getApplicationDocumentsDirectory();
    } on MissingPlatformDirectoryException {
      return const [];
    }
    if (!dir.existsSync()) return const [];

    final found = <LocalExportFile>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (p.extension(entity.path).toLowerCase() != '.$fileExtension') continue;
      try {
        found.add(
          LocalExportFile(path: entity.path, fileName: p.basename(entity.path), modified: entity.statSync().modified),
        );
      } on FileSystemException {
        // A file that vanished between listing and stat is simply not offered.
        continue;
      }
    }
    found.sort((a, b) => b.modified.compareTo(a.modified));
    return found;
  }

  /// Where [exportToFile] writes when there is no document picker, so the UI
  /// can tell the viewer where to find the file or where to put one.
  static Future<String?> localExportDirectory() async {
    try {
      return (await getApplicationDocumentsDirectory()).path;
    } on MissingPlatformDirectoryException {
      return null;
    }
  }

  /// Whether this platform reads and writes exports through the app's own
  /// documents directory instead of a document picker.
  static bool get usesLocalExportDirectory => Platform.isAndroid && PlatformDetector.isTV();
}
