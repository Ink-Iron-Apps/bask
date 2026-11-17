import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';
import '../utils/app_logger.dart';
import 'settings_handoff_service.dart';

/// One downloaded file the previous install is holding.
@immutable
class DownloadHandoffEntry {
  const DownloadHandoffEntry({required this.relativePath, required this.bytes});

  /// Path relative to the downloads folder, with `/` separators.
  final String relativePath;

  final int bytes;
}

/// What the previous install has, before anything is copied.
@immutable
class DownloadHandoffManifest {
  const DownloadHandoffManifest({required this.authority, required this.entries, required this.databaseBytes});

  final String authority;
  final List<DownloadHandoffEntry> entries;

  /// Size of the database describing the downloads, or 0 when it is absent.
  final int databaseBytes;

  int get fileBytes => entries.fold(0, (sum, entry) => sum + entry.bytes);
  int get totalBytes => fileBytes + databaseBytes;

  /// Nothing to offer. A manifest with a database but no files is still empty:
  /// rows describing files that are gone are worse than no rows.
  bool get isEmpty => entries.isEmpty;
}

/// How far a restore has got, for a progress indicator.
@immutable
class DownloadHandoffProgress {
  const DownloadHandoffProgress({
    required this.filesCopied,
    required this.filesTotal,
    required this.bytesCopied,
    required this.bytesTotal,
    this.currentPath,
  });

  final int filesCopied;
  final int filesTotal;
  final int bytesCopied;
  final int bytesTotal;
  final String? currentPath;

  double get fraction => bytesTotal == 0 ? 1 : (bytesCopied / bytesTotal).clamp(0.0, 1.0);
}

/// What a finished — or abandoned — restore actually did.
@immutable
class DownloadHandoffResult {
  const DownloadHandoffResult({
    required this.filesCopied,
    required this.filesSkipped,
    required this.filesFailed,
    required this.rowsImported,
    required this.rowsPruned,
    required this.cancelled,
  });

  final int filesCopied;

  /// Files already present at the destination at the right size, from an
  /// earlier run that was interrupted.
  final int filesSkipped;

  final int filesFailed;

  /// Download records brought across.
  final int rowsImported;

  /// Records dropped again because their file did not arrive, so the library
  /// never shows an entry that cannot be played.
  final int rowsPruned;

  final bool cancelled;

  bool get isComplete => !cancelled && filesFailed == 0;
}

typedef HandoffManifestReader = Future<Map<Object?, Object?>?> Function(List<String> authorities);

typedef HandoffFileCopier =
    Future<int> Function({
      required String authority,
      required String segment,
      required String destination,
      String? relativePath,
    });

/// Brings downloaded media across from the install this app used to be.
///
/// The settings handoff moves a small JSON file; this moves tens of gigabytes
/// and a database, so it is a separate, resumable, explicitly offered step.
/// Files are copied rather than moved: both installs keep them until the
/// viewer removes the old app, so an interrupted or disappointing migration
/// costs nothing.
///
/// Records are imported after the files they describe, and any record whose
/// file did not arrive is dropped again. A library listing something that
/// cannot be played is worse than a library that is missing it.
class DownloadHandoffService {
  DownloadHandoffService({
    HandoffManifestReader? readManifest,
    HandoffFileCopier? copyFile,
    Future<Directory> Function()? appDirectory,
    List<String>? authorities,
  }) : _readManifest = readManifest ?? _readManifestOverChannel,
       _copyFile = copyFile ?? _copyFileOverChannel,
       _appDirectory = appDirectory ?? getApplicationDocumentsDirectory,
       _authorities = authorities ?? SettingsHandoffService.legacyAuthorities;

  static const MethodChannel _channel = MethodChannel('com.plezy/settings_handoff');

  /// Matches the provider's `SEGMENT_DOWNLOADS`.
  static const String downloadsSegment = 'downloads';

  /// Matches the provider's `SEGMENT_DATABASE`.
  static const String databaseSegment = 'database';

  /// The file the previous install's database is copied to before it is read.
  /// Named so it is obviously transient if anyone finds it.
  static const String stagedDatabaseName = 'handoff-downloads.db';

  final HandoffManifestReader _readManifest;
  final HandoffFileCopier _copyFile;
  final Future<Directory> Function() _appDirectory;
  final List<String> _authorities;

  static Future<Map<Object?, Object?>?> _readManifestOverChannel(List<String> authorities) =>
      _channel.invokeMapMethod<Object?, Object?>('readDownloadManifest', {'authorities': authorities});

  static Future<int> _copyFileOverChannel({
    required String authority,
    required String segment,
    required String destination,
    String? relativePath,
  }) async {
    final copied = await _channel.invokeMethod<int>('copyHandoffFile', {
      'authority': authority,
      'segment': segment,
      'relativePath': relativePath,
      'destination': destination,
    });
    return copied ?? 0;
  }

  /// What the previous install is holding, or null when there is none.
  Future<DownloadHandoffManifest?> manifest() async {
    if (!SettingsHandoffService.isSupported) return null;
    final Map<Object?, Object?>? raw;
    try {
      raw = await _readManifest(_authorities);
    } on PlatformException catch (error, stackTrace) {
      appLogger.w('Could not read the previous install\'s downloads', error: error, stackTrace: stackTrace);
      return null;
    }
    if (raw == null) return null;

    final authority = raw['authority'] as String?;
    if (authority == null) return null;

    final paths = (raw['paths'] as List?)?.cast<Object?>() ?? const [];
    final sizes = (raw['sizes'] as List?)?.cast<Object?>() ?? const [];
    final entries = <DownloadHandoffEntry>[];
    for (var i = 0; i < paths.length; i++) {
      final path = paths[i] as String?;
      if (path == null || path.isEmpty) continue;
      final bytes = i < sizes.length ? (sizes[i] as num?)?.toInt() ?? 0 : 0;
      entries.add(DownloadHandoffEntry(relativePath: path, bytes: bytes));
    }

    return DownloadHandoffManifest(
      authority: authority,
      entries: entries,
      databaseBytes: (raw['databaseSize'] as num?)?.toInt() ?? 0,
    );
  }

  /// Copies the files, then the records that describe them.
  ///
  /// [isCancelled] is consulted between files, so cancelling leaves whole
  /// files behind rather than truncated ones and a later run resumes from
  /// there. Nothing is written to the database until the copying is done.
  Future<DownloadHandoffResult> restore({
    required DownloadHandoffManifest manifest,
    required AppDatabase database,
    void Function(DownloadHandoffProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final root = await _appDirectory();
    final downloadsRoot = Directory(p.join(root.path, downloadsSegment));
    await downloadsRoot.create(recursive: true);

    var copied = 0;
    var skipped = 0;
    var failed = 0;
    var bytesCopied = 0;
    var cancelled = false;

    void report(String? current) => onProgress?.call(
      DownloadHandoffProgress(
        filesCopied: copied,
        filesTotal: manifest.entries.length,
        bytesCopied: bytesCopied,
        bytesTotal: manifest.fileBytes,
        currentPath: current,
      ),
    );

    report(null);

    for (final entry in manifest.entries) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final destination = File(p.join(downloadsRoot.path, p.joinAll(p.posix.split(entry.relativePath))));

      // Already here at the right size, so an earlier interrupted run got it.
      // Size rather than a checksum: the source is a sibling install of this
      // app, not an untrusted download, and hashing gigabytes to re-confirm a
      // local copy costs more than it proves.
      if (await destination.exists() && await destination.length() == entry.bytes && entry.bytes > 0) {
        skipped++;
        bytesCopied += entry.bytes;
        report(entry.relativePath);
        continue;
      }

      try {
        final written = await _copyFile(
          authority: manifest.authority,
          segment: downloadsSegment,
          relativePath: entry.relativePath,
          destination: destination.path,
        );
        copied++;
        bytesCopied += written;
      } catch (error, stackTrace) {
        failed++;
        appLogger.w('Could not bring over ${entry.relativePath}', error: error, stackTrace: stackTrace);
      }
      report(entry.relativePath);
    }

    var imported = 0;
    var pruned = 0;
    if (!cancelled && manifest.databaseBytes > 0) {
      final staged = File(p.join(root.path, stagedDatabaseName));
      try {
        await _copyFile(authority: manifest.authority, segment: databaseSegment, destination: staged.path);
        imported = await importRecords(database: database, legacyDatabase: staged);
        pruned = await pruneUnplayableRecords(database: database, appDirectory: root);
      } catch (error, stackTrace) {
        appLogger.w('Could not import the previous install\'s download records', error: error, stackTrace: stackTrace);
      } finally {
        // The staged copy is a whole app database, credentials included. It
        // exists only for the length of the import and is deleted even when
        // that import throws.
        try {
          if (await staged.exists()) await staged.delete();
        } catch (error) {
          appLogger.w('Could not remove the staged handoff database: $error');
        }
      }
    }

    return DownloadHandoffResult(
      filesCopied: copied,
      filesSkipped: skipped,
      filesFailed: failed,
      rowsImported: imported,
      rowsPruned: pruned,
      cancelled: cancelled,
    );
  }

  /// Copies download rows out of [legacyDatabase] into [database].
  ///
  /// Paths are rewritten to be relative to the downloads folder as they are
  /// copied, because a stored absolute path names the old app's sandbox, which
  /// this app cannot reach. Rows holding a SAF tree URI are skipped: that
  /// permission was granted to the old package and cannot be handed over, so
  /// the file is not ours to claim.
  @visibleForTesting
  Future<int> importRecords({required AppDatabase database, required File legacyDatabase}) async {
    final escaped = legacyDatabase.path.replaceAll("'", "''");
    await database.customStatement("ATTACH DATABASE '$escaped' AS handoff");
    try {
      final before = await _countDownloads(database);
      await database.customStatement('''
        INSERT OR IGNORE INTO downloaded_media (
          server_id, client_scope_id, rating_key, global_key, type,
          parent_rating_key, grandparent_rating_key, status, progress,
          total_bytes, downloaded_bytes, video_file_path, saf_root_uri,
          thumb_path, downloaded_at, error_message, retry_count, bg_task_id,
          media_index, media_source_id
        )
        SELECT
          server_id, client_scope_id, rating_key, global_key, type,
          parent_rating_key, grandparent_rating_key, status, progress,
          total_bytes, downloaded_bytes,
          CASE
            WHEN video_file_path IS NOT NULL AND instr(video_file_path, 'downloads/') > 0
              THEN substr(video_file_path, instr(video_file_path, 'downloads/'))
            ELSE video_file_path
          END,
          saf_root_uri,
          CASE
            WHEN thumb_path IS NOT NULL AND instr(thumb_path, 'downloads/') > 0
              THEN substr(thumb_path, instr(thumb_path, 'downloads/'))
            ELSE thumb_path
          END,
          downloaded_at, error_message, retry_count, bg_task_id,
          media_index, media_source_id
        FROM handoff.downloaded_media
        WHERE saf_root_uri IS NULL
      ''');

      // Ownership follows the files, but only for rows that actually arrived.
      await database.customStatement('''
        INSERT OR IGNORE INTO download_owners (profile_id, global_key, backend, client_scope_id, created_at)
        SELECT profile_id, global_key, backend, client_scope_id, created_at
        FROM handoff.download_owners
        WHERE global_key IN (SELECT global_key FROM downloaded_media)
      ''');

      return await _countDownloads(database) - before;
    } finally {
      await database.customStatement('DETACH DATABASE handoff');
    }
  }

  /// Removes imported records whose file is not on disk.
  @visibleForTesting
  Future<int> pruneUnplayableRecords({required AppDatabase database, required Directory appDirectory}) async {
    final rows = await database
        .customSelect('SELECT global_key, video_file_path FROM downloaded_media WHERE saf_root_uri IS NULL')
        .get();

    final orphaned = <String>[];
    for (final row in rows) {
      final key = row.read<String>('global_key');
      final stored = row.data['video_file_path'] as String?;
      if (stored == null || stored.isEmpty) continue;
      final absolute = p.isAbsolute(stored) ? stored : p.join(appDirectory.path, stored);
      if (!await File(absolute).exists()) orphaned.add(key);
    }
    if (orphaned.isEmpty) return 0;

    final list = orphaned.map((key) => "'${key.replaceAll("'", "''")}'").join(',');
    await database.customStatement('DELETE FROM download_owners WHERE global_key IN ($list)');
    await database.customStatement('DELETE FROM downloaded_media WHERE global_key IN ($list)');
    return orphaned.length;
  }

  Future<int> _countDownloads(AppDatabase database) async {
    final row = await database.customSelect('SELECT COUNT(*) AS c FROM downloaded_media').getSingle();
    return row.read<int>('c');
  }
}
