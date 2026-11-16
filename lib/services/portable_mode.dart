import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';

import '../utils/app_logger.dart';

/// Keeps every file the app writes inside its own folder on Windows.
///
/// A portable copy is one you can put on a stick, run from anywhere, and
/// delete by deleting the folder — which is only true if nothing leaks into
/// `%APPDATA%`. By default Flutter's path_provider sends application support,
/// cache and documents there, so the database, preferences, artwork cache,
/// subtitle fonts, logs and downloads would all outlive the folder and would
/// not travel with it.
///
/// Opt-in by a marker file rather than a build flag: the same executable then
/// serves both modes, an installed copy is unaffected, and turning a normal
/// copy portable is creating one empty file.
class PortableMode {
  PortableMode._();

  /// Marker checked next to the executable. Name and extension chosen to be
  /// obvious to whoever finds it in the folder.
  static const String markerFileName = 'portable.txt';

  /// Subdirectory holding everything the app writes in portable mode.
  ///
  /// Not `data`: a Flutter Windows bundle already ships a `data` folder next
  /// to the executable holding flutter_assets and icudtl.dat. Writing the
  /// database and caches in there would mix user state into the program's
  /// own files, and an update that replaces the bundle would take them with
  /// it.
  static const String dataDirectoryName = 'bask-data';

  /// The folder this app wrote to when it was called Bask.
  ///
  /// Renaming the app renamed its data folder, and a portable copy is the one
  /// install with no package manager and no sandbox to carry state across
  /// that change: the folder beside the executable is the whole install. A
  /// copy updated in place would otherwise come up empty with its old
  /// settings sitting untouched one directory over, so the first run after
  /// the rename adopts the old folder instead.
  static const String legacyDataDirectoryName = 'plexy-data';

  static bool _initialized = false;
  static Directory? _root;

  /// Where portable data lives, or null when this is not a portable copy.
  static Directory? get root => _root;

  static bool get isActive => _root != null;

  /// The portable application support folder, or null when not portable.
  ///
  /// The same folder [PortablePathProvider] answers with, resolved eagerly so
  /// a caller outside path_provider — the downloader's storage isolate — can
  /// be handed a path rather than a provider.
  static String? get supportPath => _root == null ? null : PortablePathProvider(_root!.path)._ensure('support');

  /// Rename a pre-rename data folder into place, once.
  ///
  /// Only ever moves when the new folder does not exist yet, so a copy that
  /// has already run under the new name never has its state replaced by
  /// whatever the old folder still holds. A failure here is not fatal: the
  /// caller goes on to create an empty folder, which is the same state the
  /// install would have been in without the migration.
  static void _adoptLegacyDataDirectory(String exeDir, Directory data) {
    if (data.existsSync()) return;
    final legacy = Directory(p.join(exeDir, legacyDataDirectoryName));
    if (!legacy.existsSync()) return;
    try {
      legacy.renameSync(data.path);
      appLogger.i('Portable mode: adopted $legacyDataDirectoryName as $dataDirectoryName');
    } catch (e, stackTrace) {
      appLogger.w(
        'Portable mode: could not adopt the $legacyDataDirectoryName folder; starting fresh',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Detect the marker and redirect path_provider at it.
  ///
  /// Must run before anything reads a path — the database, preferences and
  /// caches all resolve theirs once and keep them. Safe to call on every
  /// platform: only Windows can be portable, and everything else returns
  /// immediately.
  static void initialize({String? executablePathOverride, bool registerPlatform = true}) {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isWindows) return;

    try {
      final exeDir = p.dirname(executablePathOverride ?? Platform.resolvedExecutable);
      final marker = File(p.join(exeDir, markerFileName));
      if (!marker.existsSync()) return;

      final data = Directory(p.join(exeDir, dataDirectoryName));
      _adoptLegacyDataDirectory(exeDir, data);
      data.createSync(recursive: true);

      // A folder the user cannot write to would fail later, one file at a
      // time, in whichever subsystem happened to write first. Prove it now.
      final probe = File(p.join(data.path, '.write-probe'));
      probe.writeAsStringSync('');
      probe.deleteSync();

      _root = data;
      if (registerPlatform) {
        PathProviderPlatform.instance = PortablePathProvider(data.path);
      }
      appLogger.i('Portable mode: writing everything under ${data.path}');
    } catch (e, stackTrace) {
      // A portable copy on read-only media, or one the user cannot write to,
      // falls back to the normal locations rather than failing to start. The
      // log says which, because the difference matters when the settings
      // "did not save".
      _root = null;
      appLogger.w(
        'Portable mode requested but unavailable; using the default locations',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _initialized = false;
    _root = null;
  }
}

/// A [PathProviderWindows] that answers with subdirectories of the portable
/// data folder.
///
/// Extends the Windows implementation rather than the interface because the
/// vendored shared_preferences plugin holds a [PathProviderWindows] and calls
/// it directly; a bare interface implementation would redirect the app but
/// leave preferences behind in `%APPDATA%`.
class PortablePathProvider extends PathProviderWindows {
  PortablePathProvider(this.rootPath);

  final String rootPath;

  String _ensure(String name) {
    final dir = Directory(p.join(rootPath, name));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async => _ensure('support');

  @override
  Future<String?> getApplicationDocumentsPath() async => _ensure('documents');

  @override
  Future<String?> getApplicationCachePath() async => _ensure('cache');

  @override
  Future<String?> getTemporaryPath() async => _ensure('cache');

  @override
  Future<String?> getDownloadsPath() async => _ensure('downloads');
}
