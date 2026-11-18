import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../database/app_database.dart';
import '../database/download_operations.dart';
import '../models/download_models.dart';
import '../utils/app_logger.dart';
import 'download_storage_service.dart';
import 'settings_export_service.dart';
import 'settings_service.dart';
import 'shared_storage_service.dart';

/// The descriptor a predecessor install leaves beside the media it moved into
/// shared storage.
///
/// Plain JSON on purpose: it has to be readable by an app that shares no code
/// version and no signing key with the one that wrote it. Its presence is the
/// signal that the folder is complete — the writer only writes it once every
/// planned file has arrived — so finding one is what makes the folder safe to
/// adopt rather than merely present.
@immutable
class SharedLibraryDescriptor {
  const SharedLibraryDescriptor({
    required this.root,
    required this.version,
    required this.downloadsFolder,
    required this.artworkFolder,
    required this.fileCount,
    this.writtenAt,
    this.settingsFile,
    this.rowsFile,
  });

  /// The shared library folder itself, which every path below is relative to.
  final Directory root;

  final int version;

  /// When the library finished moving, when the writer recorded it.
  final DateTime? writtenAt;

  /// Subfolder holding the media, relative to [root].
  final String downloadsFolder;

  /// Subfolder holding cached artwork, relative to [root].
  ///
  /// May be empty on disk. Artwork is a refetchable cache and a writer that
  /// had none to move leaves the folder empty rather than failing, so an empty
  /// one must never be read as a failed move.
  final String artworkFolder;

  /// How many media files the writer moved. The number to reconcile against.
  final int fileCount;

  /// Name of the settings export sitting beside the media, when there is one.
  final String? settingsFile;

  /// Name of the download records sitting beside the media, when there are
  /// any. See [SharedLibraryAdoptionService.defaultRowsFileName].
  final String? rowsFile;

  String get downloadsPath => p.join(root.path, downloadsFolder);
  String get artworkPath => p.join(root.path, artworkFolder);

  File? get settingsBackup => settingsFile == null ? null : File(p.join(root.path, settingsFile!));
  File get rows => File(p.join(root.path, rowsFile ?? SharedLibraryAdoptionService.defaultRowsFileName));

  /// Reads a descriptor out of [contents], or returns null when it is not one
  /// this app understands.
  ///
  /// A version it does not recognise is refused rather than guessed at: the
  /// folder holds tens of gigabytes described by a schema this build has never
  /// seen, and half-adopting that is worse than leaving it alone.
  static SharedLibraryDescriptor? parse(Directory root, String contents) {
    final Object? decoded;
    try {
      decoded = json.decode(contents);
    } on FormatException catch (error) {
      appLogger.w('The shared library descriptor is not valid JSON: $error');
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    final version = (decoded['version'] as num?)?.toInt();
    if (version != SharedLibraryAdoptionService.descriptorVersion) {
      appLogger.w('Ignoring a shared library descriptor written at version $version');
      return null;
    }

    final downloads = decoded['downloadsFolder'] as String?;
    if (downloads == null || downloads.isEmpty) return null;

    return SharedLibraryDescriptor(
      root: root,
      version: version!,
      writtenAt: DateTime.tryParse(decoded['writtenAt'] as String? ?? '')?.toUtc(),
      downloadsFolder: downloads,
      artworkFolder: decoded['artworkFolder'] as String? ?? 'artwork',
      fileCount: (decoded['fileCount'] as num?)?.toInt() ?? 0,
      settingsFile: decoded['settingsFile'] as String?,
      rowsFile: decoded['rowsFile'] as String?,
    );
  }
}

/// What adopting the folder actually did.
@immutable
class SharedLibraryAdoptionResult {
  const SharedLibraryAdoptionResult({
    required this.downloadsPath,
    required this.adoptedRoot,
    required this.rowsImported,
    required this.rowsPruned,
    required this.filesOnDisk,
    required this.filesClaimed,
    required this.expectedFileCount,
    required this.settingsImported,
    required this.credentialsSkipped,
  });

  final String downloadsPath;

  /// Whether new downloads will now land in the shared folder too. False when
  /// the folder turned out not to be writable, which leaves the library in
  /// app-private storage rather than splitting it across two roots.
  final bool adoptedRoot;

  /// Download records brought across.
  final int rowsImported;

  /// Records dropped again because the file they name is not in the folder, so
  /// the library never lists something that cannot be played.
  final int rowsPruned;

  /// Media files found in the folder, whatever the records say about them.
  final int filesOnDisk;

  /// Files a record now points at.
  final int filesClaimed;

  /// What the descriptor said the folder holds.
  final int expectedFileCount;

  final bool settingsImported;

  /// The settings file carried credentials that were left alone, because no
  /// passphrase was offered.
  final bool credentialsSkipped;

  /// Files sitting in the folder that no record claims. They stay exactly
  /// where they are — a file nothing describes is not a file worth deleting —
  /// but they are reported, because they are the difference between what the
  /// viewer can see and what is on their device.
  int get filesUnclaimed => filesOnDisk - filesClaimed;

  /// Whether every file the folder holds is now playable.
  bool get isComplete => adoptedRoot && filesUnclaimed == 0 && filesOnDisk >= expectedFileCount;
}

/// One download record as the shared folder describes it.
@immutable
class SharedLibraryRow {
  const SharedLibraryRow({
    required this.serverId,
    required this.ratingKey,
    required this.globalKey,
    required this.type,
    required this.videoFile,
    this.parentRatingKey,
    this.grandparentRatingKey,
    this.totalBytes,
    this.downloadedAt,
    this.mediaIndex = 0,
    this.mediaSourceId,
    this.thumbFile,
  });

  final String serverId;
  final String ratingKey;
  final String globalKey;
  final String type;

  /// Path of the media file relative to the descriptor's downloads folder,
  /// with `/` separators.
  final String videoFile;

  /// Name of the artwork file inside the descriptor's artwork folder. Artwork
  /// is a flat folder of hashed names, so the name is the whole address.
  final String? thumbFile;

  final String? parentRatingKey;
  final String? grandparentRatingKey;
  final int? totalBytes;
  final int? downloadedAt;
  final int mediaIndex;
  final String? mediaSourceId;

  static SharedLibraryRow? parse(Object? source) {
    if (source is! Map<String, dynamic>) return null;
    String? text(String key) {
      final value = source[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final serverId = text('serverId');
    final ratingKey = text('ratingKey');
    final videoFile = text('videoFile');
    final type = text('type');
    if (serverId == null || ratingKey == null || videoFile == null || type == null) return null;

    return SharedLibraryRow(
      serverId: serverId,
      ratingKey: ratingKey,
      // Derived when absent rather than demanded: the key is `serverId:ratingKey`
      // by construction, and a writer that omits it has still said everything
      // needed to rebuild it.
      globalKey: text('globalKey') ?? '$serverId:$ratingKey',
      type: type,
      videoFile: videoFile,
      thumbFile: text('thumbFile'),
      parentRatingKey: text('parentRatingKey'),
      grandparentRatingKey: text('grandparentRatingKey'),
      totalBytes: (source['totalBytes'] as num?)?.toInt(),
      downloadedAt: (source['downloadedAt'] as num?)?.toInt(),
      mediaIndex: (source['mediaIndex'] as num?)?.toInt() ?? 0,
      mediaSourceId: text('mediaSourceId'),
    );
  }
}

/// Adopts an offline library a predecessor install left in shared storage.
///
/// The counterpart of the move that put it there. App-private storage is
/// deleted with the app, so a rename, a reinstall or a new signing key would
/// otherwise cost the whole library; a folder on the shared volume survives
/// all three, and this is the side that picks it up. Nothing is copied and
/// nothing is moved — the folder becomes this install's download root where it
/// already lies, so adopting 125 GB costs one preference write.
///
/// Three things come out of the folder, in this order:
///
/// * **The settings**, from the export the writer left beside the media. It
///   carries no download path of its own — device storage locations are
///   deliberately outside the portable set — so it can never contradict the
///   root adopted next.
/// * **The download root**, so the media is where the app looks for it and new
///   downloads join it rather than starting a second library in app-private
///   storage.
/// * **The records**, from the rows file, with every path rewritten to the
///   folder they now live in. A record whose file is not there is dropped: a
///   library listing something that cannot be played is worse than one missing
///   it.
///
/// Records have to travel as data rather than as a database. The provider that
/// hands a successor a whole database re-checks the caller's signing key, and
/// the install that did the move is signed with the key this app replaced, so
/// that route is closed by construction. A JSON file in the folder is also the
/// only one of the two that carries no credentials.
///
/// ## What a writer has to leave in the folder
///
/// `library.json`, as the move already writes it:
///
/// ```json
/// {
///   "version": 1,
///   "writtenAt": "2026-11-18T10:04:51.629798Z",
///   "downloadsFolder": "downloads",
///   "artworkFolder": "artwork",
///   "fileCount": 16,
///   "settingsFile": "plezy-settings-auto-2026-11-18T10-04-51-620948Z.json",
///   "rowsFile": "downloads.json"
/// }
/// ```
///
/// `rowsFile` is optional and defaults to [defaultRowsFileName]. The records
/// themselves, one object per downloaded item:
///
/// ```json
/// {
///   "version": 1,
///   "downloads": [
///     {
///       "serverId": "a1b2c3",
///       "ratingKey": "54321",
///       "globalKey": "a1b2c3:54321",
///       "type": "movie",
///       "videoFile": "Movies/Arrival (2016)/Arrival (2016).mkv",
///       "thumbFile": "9f86d081.jpg",
///       "totalBytes": 8589934592,
///       "downloadedAt": 1763462691000,
///       "mediaIndex": 0,
///       "mediaSourceId": null,
///       "parentRatingKey": null,
///       "grandparentRatingKey": null
///     }
///   ]
/// }
/// ```
///
/// `serverId`, `ratingKey`, `type` and `videoFile` are required; `globalKey`
/// is derived from the first two when absent and everything else is optional.
/// `videoFile` is relative to `downloadsFolder` with `/` separators, and
/// `thumbFile` is a filename inside `artworkFolder`. `downloadedAt` is epoch
/// milliseconds. Ownership, profile ids and client scopes are deliberately not
/// part of the contract — see [importRows] for why carrying them would hide
/// the library rather than hand it over.
class SharedLibraryAdoptionService {
  SharedLibraryAdoptionService({
    SharedStorageService? storage,
    DownloadStorageService? downloads,
    SettingsService? settings,
    this.setDownloadLocation,
    @visibleForTesting Future<Directory?> Function()? libraryRoot,
    @visibleForTesting Future<SharedLibraryDescriptor?> Function()? readDescriptor,
  }) : _injectedStorage = storage,
       _injectedDownloads = downloads,
       _injectedSettings = settings,
       _libraryRootOverride = libraryRoot,
       _descriptorOverride = readDescriptor;

  // Resolved on use, not in the constructor. Each of these singletons insists
  // on having been initialized, and a service that is only being asked whether
  // there is anything to adopt has no business demanding platform setup it
  // never touches.
  final SharedStorageService? _injectedStorage;
  final DownloadStorageService? _injectedDownloads;
  final SettingsService? _injectedSettings;

  SharedStorageService get _storage => _injectedStorage ?? SharedStorageService.instance;
  DownloadStorageService get _downloads => _injectedDownloads ?? DownloadStorageService.instance;
  SettingsService get _settings => _injectedSettings ?? SettingsService.instance;

  final Future<Directory?> Function()? _libraryRootOverride;

  /// Test seam for the folder read.
  ///
  /// Reading the descriptor is real file IO, which does not complete inside
  /// the fake async a widget test runs in, so the UI around this service is
  /// tested against a descriptor handed in rather than one on disk. The read
  /// itself is covered in the service's own tests.
  final Future<SharedLibraryDescriptor?> Function()? _descriptorOverride;

  /// How the download root is changed, when a caller has the full transition
  /// to hand.
  ///
  /// The manager's version does more than write two preferences: it rolls the
  /// pair back together when the second write or the refresh fails, and it
  /// releases a SAF grant the install is moving away from. Neither matters on
  /// the fresh install this is built for, and both matter when somebody adopts
  /// a folder from Settings on an install that already had a root — so the
  /// caller that can reach the manager passes it in, and the fallback below
  /// keeps this service usable without one.
  final Future<void> Function(String path, String pathType)? setDownloadLocation;

  Future<Directory?> _libraryRoot() async =>
      _libraryRootOverride != null ? await _libraryRootOverride() : await _storage.libraryDirectory();

  /// The descriptor file both sides of the handover agree on.
  static const String descriptorName = 'library.json';

  /// Where the download records live when the descriptor does not name them.
  static const String defaultRowsFileName = 'downloads.json';

  static const int descriptorVersion = 1;

  static const int rowsVersion = 1;

  /// Extensions counted as media when reconciling the folder against the
  /// records. Deliberately a list of containers rather than "every file":
  /// subtitles, artwork and the descriptor itself are not downloads.
  static const Set<String> mediaExtensions = {
    '.mkv',
    '.mp4',
    '.m4v',
    '.avi',
    '.mov',
    '.ts',
    '.m2ts',
    '.webm',
    '.mpg',
    '.mpeg',
    '.wmv',
    '.flac',
    '.mp3',
    '.m4a',
    '.ogg',
    '.opus',
    '.wav',
    '.aac',
  };

  /// Whether this device could have a library to adopt at all.
  Future<bool> get isAvailable async {
    if (!SharedStorageService.isSupported && _libraryRootOverride == null) return false;
    return await _libraryRoot() != null;
  }

  /// The descriptor in the shared library folder, or null when there is none.
  ///
  /// Needs shared-storage access to be granted already: without it the folder
  /// is not merely empty but unreadable, and this returns null the same as if
  /// nobody had ever left anything there. Callers ask for the permission first
  /// and look afterwards.
  Future<SharedLibraryDescriptor?> descriptor() async {
    final override = _descriptorOverride;
    if (override != null) return override();

    final root = await _libraryRoot();
    if (root == null) return null;

    final file = File(p.join(root.path, descriptorName));
    try {
      if (!await file.exists()) return null;
      return SharedLibraryDescriptor.parse(root, await file.readAsString());
    } on FileSystemException catch (error) {
      // Unreadable is not the same as absent, and the difference matters when
      // somebody is wondering why their library did not turn up.
      appLogger.w('Could not read the shared library descriptor', error: error);
      return null;
    }
  }

  /// Whether the folder in [descriptor] is already this install's download
  /// root, so there is nothing left to adopt.
  bool isAlreadyAdopted(SharedLibraryDescriptor descriptor) {
    final current = _settings.read(SettingsService.customDownloadPath);
    if (current == null || current.isEmpty) return false;
    return p.equals(current, descriptor.downloadsPath);
  }

  /// Adopts [descriptor]'s folder: the download root, then the settings, then
  /// the records.
  ///
  /// The root comes first because everything else depends on it. A folder that
  /// cannot be written is not adopted at all and nothing else is read from it:
  /// records pointing into a folder the app cannot manage would give a library
  /// whose entries refuse to delete, which is worse than one that stayed where
  /// it was. Past that point each step stands alone — a settings file that will
  /// not import does not stop the media, and records that will not parse do
  /// not un-adopt the root.
  Future<SharedLibraryAdoptionResult> adopt({
    required SharedLibraryDescriptor descriptor,
    required AppDatabase database,
    Future<String?> Function()? passphraseProvider,
  }) async {
    final downloads = Directory(descriptor.downloadsPath);
    final adoptedRoot = await _adoptAsDownloadRoot(downloads);
    if (!adoptedRoot) {
      return SharedLibraryAdoptionResult(
        downloadsPath: descriptor.downloadsPath,
        adoptedRoot: false,
        rowsImported: 0,
        rowsPruned: 0,
        filesOnDisk: await countMediaFiles(downloads),
        filesClaimed: 0,
        expectedFileCount: descriptor.fileCount,
        settingsImported: false,
        credentialsSkipped: false,
      );
    }

    var settingsImported = false;
    var credentialsSkipped = false;

    final backup = descriptor.settingsBackup;
    if (backup != null && await backup.exists()) {
      try {
        final result = await SettingsExportService.importFromPath(
          backup.path,
          database: database,
          passphraseProvider: passphraseProvider,
        );
        settingsImported = result != null;
        credentialsSkipped = result?.credentialsSkipped ?? false;
        _settings.refreshListenables();
      } catch (error, stackTrace) {
        // The media is the expensive half and does not depend on this.
        appLogger.w('Could not import the shared library settings', error: error, stackTrace: stackTrace);
      }
    }

    final imported = await importRows(descriptor: descriptor, database: database);
    final pruned = await pruneUnplayableRows(descriptor: descriptor, database: database);
    final claimed = await _claimedFileCount(descriptor: descriptor, database: database);
    final onDisk = await countMediaFiles(downloads);

    appLogger.i(
      'Shared library: adopted ${descriptor.downloadsPath} '
      '($imported record(s) imported, $pruned pruned, $claimed of $onDisk file(s) claimed)',
    );

    return SharedLibraryAdoptionResult(
      downloadsPath: descriptor.downloadsPath,
      adoptedRoot: adoptedRoot,
      rowsImported: imported,
      rowsPruned: pruned,
      filesOnDisk: onDisk,
      filesClaimed: claimed,
      expectedFileCount: descriptor.fileCount,
      settingsImported: settingsImported,
      credentialsSkipped: credentialsSkipped,
    );
  }

  /// Points the download root at [downloads], having proved it writable.
  ///
  /// A root that cannot be written would fail later, one download at a time,
  /// inside whichever subsystem happened to write first. It is proved here
  /// instead, and a folder that fails is simply not adopted.
  Future<bool> _adoptAsDownloadRoot(Directory downloads) async {
    try {
      final install = setDownloadLocation;
      if (install != null) {
        // Throws rather than returns on an unwritable folder, and has already
        // put the previous root back by then.
        await install(downloads.path, 'file');
        return true;
      }
      if (!await _downloads.isDirectoryWritable(downloads)) {
        appLogger.w('Not adopting ${downloads.path}: it cannot be written');
        return false;
      }
      await _settings.write(SettingsService.customDownloadPath, downloads.path);
      await _settings.write(SettingsService.customDownloadPathType, 'file');
      await _downloads.refreshCustomPath();
      return true;
    } catch (error, stackTrace) {
      appLogger.w('Could not adopt ${downloads.path} as the download root', error: error, stackTrace: stackTrace);
      return false;
    }
  }

  /// Reads the records out of the folder, or an empty list when there are
  /// none to read.
  @visibleForTesting
  Future<List<SharedLibraryRow>> readRows(SharedLibraryDescriptor descriptor) async {
    final file = descriptor.rows;
    final String contents;
    try {
      if (!await file.exists()) return const [];
      contents = await file.readAsString();
    } on FileSystemException catch (error) {
      appLogger.w('Could not read the shared library records', error: error);
      return const [];
    }

    final Object? decoded;
    try {
      decoded = json.decode(contents);
    } on FormatException catch (error) {
      appLogger.w('The shared library records are not valid JSON: $error');
      return const [];
    }
    if (decoded is! Map<String, dynamic>) return const [];

    final version = (decoded['version'] as num?)?.toInt();
    if (version != rowsVersion) {
      appLogger.w('Ignoring shared library records written at version $version');
      return const [];
    }

    final rows = <SharedLibraryRow>[];
    for (final entry in (decoded['downloads'] as List?) ?? const []) {
      final row = SharedLibraryRow.parse(entry);
      if (row != null) rows.add(row);
    }
    return rows;
  }

  /// Inserts the folder's records, rewritten to point into the folder.
  ///
  /// Three things are deliberately not carried across:
  ///
  /// * **Ownership.** The rows name the profiles of the install that wrote
  ///   them, which do not exist here. Records arrive ownerless and the active
  ///   profile claims them through the same path that claims any pre-profile
  ///   download, so they land on whoever is signed in rather than on an id
  ///   nobody holds.
  /// * **The client scope.** A Plex scope names the writing install's profile,
  ///   and a row still carrying one is skipped by that claim for good. Cleared
  ///   so the generic claim applies.
  /// * **A record whose file is absent.** Checked before the insert, not
  ///   after, so a half-moved folder cannot produce a library full of entries
  ///   that will not play.
  ///
  /// An existing row for the same key wins: this install downloading something
  /// itself is more current than a description of it written before the app
  /// was even installed.
  @visibleForTesting
  Future<int> importRows({required SharedLibraryDescriptor descriptor, required AppDatabase database}) async {
    final rows = await readRows(descriptor);
    if (rows.isEmpty) return 0;

    final existing = (await database.allDownloadedMedia()).map((row) => row.globalKey).toSet();
    var imported = 0;

    for (final row in rows) {
      if (existing.contains(row.globalKey)) continue;

      final video = File(p.join(descriptor.downloadsPath, p.joinAll(p.posix.split(row.videoFile))));
      if (!await video.exists()) continue;

      String? thumb;
      if (row.thumbFile != null) {
        final candidate = File(p.join(descriptor.artworkPath, p.basename(row.thumbFile!)));
        if (await candidate.exists()) thumb = candidate.path;
      }

      try {
        await database.into(database.downloadedMedia).insert(
          DownloadedMediaCompanion.insert(
            serverId: row.serverId,
            ratingKey: row.ratingKey,
            globalKey: row.globalKey,
            type: row.type,
            parentRatingKey: Value(row.parentRatingKey),
            grandparentRatingKey: Value(row.grandparentRatingKey),
            status: DownloadStatus.completed.index,
            progress: const Value(100),
            totalBytes: Value(row.totalBytes),
            downloadedBytes: Value(row.totalBytes ?? await video.length()),
            videoFilePath: Value(video.path),
            thumbPath: Value(thumb),
            downloadedAt: Value(row.downloadedAt),
            mediaIndex: Value(row.mediaIndex),
            mediaSourceId: Value(row.mediaSourceId),
          ),
        );
        existing.add(row.globalKey);
        imported++;
      } catch (error, stackTrace) {
        // One unusable record is not worth failing the rest of a library over.
        appLogger.w('Could not import the record for ${row.globalKey}', error: error, stackTrace: stackTrace);
      }
    }
    return imported;
  }

  /// Removes records pointing into the adopted folder at a file that is not
  /// there.
  ///
  /// Scoped to the folder on purpose: a record naming a file in app-private
  /// storage is this install's own and is none of this operation's business,
  /// however broken it may be.
  @visibleForTesting
  Future<int> pruneUnplayableRows({
    required SharedLibraryDescriptor descriptor,
    required AppDatabase database,
  }) async {
    final root = descriptor.downloadsPath;
    final orphaned = <String>[];

    for (final row in await database.allDownloadedMedia()) {
      final stored = row.videoFilePath;
      if (stored == null || stored.isEmpty) continue;
      if (!p.isWithin(root, stored)) continue;
      if (!await File(stored).exists()) orphaned.add(row.globalKey);
    }

    for (final key in orphaned) {
      await database.deleteDownload(key);
    }
    return orphaned.length;
  }

  /// How many files in the adopted folder a record now points at.
  Future<int> _claimedFileCount({
    required SharedLibraryDescriptor descriptor,
    required AppDatabase database,
  }) async {
    final root = descriptor.downloadsPath;
    final claimed = <String>{};
    for (final row in await database.allDownloadedMedia()) {
      final stored = row.videoFilePath;
      if (stored == null || stored.isEmpty) continue;
      if (p.isWithin(root, stored)) claimed.add(p.normalize(stored));
    }
    return claimed.length;
  }

  /// Media files in [directory] and below.
  @visibleForTesting
  Future<int> countMediaFiles(Directory directory) async {
    if (!await directory.exists()) return 0;
    var count = 0;
    try {
      await for (final entity in directory.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (!mediaExtensions.contains(p.extension(entity.path).toLowerCase())) continue;
        count++;
      }
    } on FileSystemException catch (error) {
      appLogger.w('Could not list ${directory.path}', error: error);
    }
    return count;
  }
}
