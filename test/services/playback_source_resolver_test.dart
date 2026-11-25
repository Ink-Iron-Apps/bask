import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:bask/media/ids.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bask/database/app_database.dart';
import 'package:bask/media/media_backend.dart';

import 'package:bask/media/media_kind.dart';
import 'package:bask/media/media_server_client.dart';
import 'package:bask/models/download_models.dart';
import 'package:bask/models/transcode_quality_preset.dart';
import 'package:bask/services/download_storage_service.dart';
import 'package:bask/services/multi_server_manager.dart';
import 'package:bask/services/playback_context.dart';
import 'package:bask/services/playback_initialization_types.dart';
import 'package:bask/services/playback_source_resolver.dart';
import '../test_helpers/io_fakes.dart';
import '../test_helpers/media_items.dart';

class _PlaybackClient implements MediaServerClient {
  _PlaybackClient({this.clientBackend = MediaBackend.plex, PlaybackInitializationResult? result})
    : result =
          result ??
          PlaybackInitializationResult(availableVersions: const [], videoUrl: 'https://example.com/video.mp4');

  final MediaBackend clientBackend;
  final PlaybackInitializationResult result;

  @override
  ServerId get serverId => ServerId('srv');

  @override
  MediaBackend get backend => clientBackend;

  @override
  double get watchedThreshold => 0.9;

  @override
  Map<String, String> get streamHeaders => const {'X-Test': 'token'};

  @override
  void close() {}

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async => result;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a downloaded copy plays from disk under a preset nobody picked for this playback', () async {
    // A preset caps what to ask the server for, and local playback asks for
    // nothing — so a device left on its saved 1080p default used to stream a
    // file it already had, at a cost in bandwidth and a server transcode. A
    // quality picked in the player for this session still wins (issue #2466),
    // which is what `downloadOutranksQuality: false` says.
    final tmpRoot = await Directory.systemTemp.createTemp('playback_resolver_test_');
    final videoFile = File('${tmpRoot.path}/movie-1.mkv');
    await videoFile.writeAsString('video');
    final previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    DownloadStorageService.resetForTesting();

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final manager = MultiServerManager();
    addTearDown(() async {
      manager.dispose();
      await db.close();
      PathProviderPlatform.instance = previousPathProvider;
      DownloadStorageService.resetForTesting();
      if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
    });

    await db
        .into(db.downloadedMedia)
        .insert(
          DownloadedMediaCompanion.insert(
            serverId: ServerId('srv'),
            ratingKey: 'movie-1',
            globalKey: 'srv:movie-1',
            type: 'movie',
            status: DownloadStatus.completed.index,
            videoFilePath: Value(videoFile.path),
            mediaIndex: const Value(0),
          ),
        );

    final client = _PlaybackClient();
    manager.debugRegisterClientForTesting(client, online: true);

    final context = await PlaybackSourceResolver(serverManager: manager, database: db).resolve(
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: 'movie-1', backend: MediaBackend.plex, kind: MediaKind.movie, serverId: 'srv'),
        selectedMediaIndex: 0,
        qualityPreset: TranscodeQualityPreset.p1080_10mbps,
      ),
      offlineLibraryMode: false,
      downloadOutranksQuality: true,
    );

    expect(context.sourceKind, PlaybackSourceKind.localFile);
    expect(context.result.videoUrl, contains('movie-1.mkv'));
    // Still an online session: progress and watched state go to the server,
    // with the offline queue only as a fallback.
    expect(context.reportingMode, PlaybackReportingMode.onlineWithOfflineFallback);
  });

  test('online playback uses registered client even when status is stale offline', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final manager = MultiServerManager();
    addTearDown(() async {
      manager.dispose();
      await db.close();
    });

    final client = _PlaybackClient();
    manager.debugRegisterClientForTesting(client, online: false);

    final context = await PlaybackSourceResolver(serverManager: manager, database: db).resolve(
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: 'item-1', backend: MediaBackend.plex, kind: MediaKind.movie, serverId: 'srv'),
        selectedMediaIndex: 0,
        qualityPreset: TranscodeQualityPreset.original,
      ),
      offlineLibraryMode: false,
    );

    expect(context.result.videoUrl, 'https://example.com/video.mp4');
    expect(context.reportingClient, same(client));
    expect(context.reportingMode, PlaybackReportingMode.online);
  });

  test('offline launch cannot fall through to a live server when the download is missing', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final manager = MultiServerManager();
    addTearDown(() async {
      manager.dispose();
      await db.close();
    });
    manager.debugRegisterClientForTesting(_PlaybackClient(), online: true);
    await expectLater(
      PlaybackSourceResolver(serverManager: manager, database: db).resolve(
        PlaybackInitializationOptions(
          metadata: testMediaItem(
            id: 'missing-download',
            backend: MediaBackend.plex,
            kind: MediaKind.movie,
            serverId: 'srv',
          ),
          selectedMediaIndex: 0,
          qualityPreset: TranscodeQualityPreset.original,
        ),
        offlineLibraryMode: true,
      ),
      throwsA(
        isA<PlaybackException>().having((error) => error.reason, 'reason', PlaybackFailureReason.noPlayableSource),
      ),
    );
  });

  test('plex direct playback adds playback session header to stream headers', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final manager = MultiServerManager();
    addTearDown(() async {
      manager.dispose();
      await db.close();
    });

    final client = _PlaybackClient();
    manager.debugRegisterClientForTesting(client, online: true);

    final context = await PlaybackSourceResolver(serverManager: manager, database: db).resolve(
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: 'item-1', backend: MediaBackend.plex, kind: MediaKind.movie, serverId: 'srv'),
        selectedMediaIndex: 0,
        qualityPreset: TranscodeQualityPreset.original,
        sessionIdentifier: 'playback-session-id',
      ),
      offlineLibraryMode: false,
    );

    expect(context.sourceKind, PlaybackSourceKind.remoteDirect);
    expect(context.streamHeaders, containsPair('X-Test', 'token'));
    expect(context.streamHeaders, containsPair('X-Plex-Session-Identifier', 'playback-session-id'));
  });

  test('non-plex direct playback does not add plex session header', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final manager = MultiServerManager();
    addTearDown(() async {
      manager.dispose();
      await db.close();
    });

    final client = _PlaybackClient(clientBackend: MediaBackend.jellyfin);
    manager.debugRegisterClientForTesting(client, online: true);

    final context = await PlaybackSourceResolver(serverManager: manager, database: db).resolve(
      PlaybackInitializationOptions(
        metadata: testMediaItem(id: 'item-1', backend: MediaBackend.jellyfin, kind: MediaKind.movie, serverId: 'srv'),
        selectedMediaIndex: 0,
        qualityPreset: TranscodeQualityPreset.original,
        sessionIdentifier: 'playback-session-id',
      ),
      offlineLibraryMode: false,
    );

    expect(context.sourceKind, PlaybackSourceKind.remoteDirect);
    expect(context.streamHeaders, isNot(contains('X-Plex-Session-Identifier')));
  });

  group('the playback source line', () {
    test('names a local file in full, because a path is not a secret', () {
      expect(
        PlaybackSourceResolver.describeSource(
          PlaybackSourceKind.localFile,
          '/storage/emulated/0/Bask/downloads/Movies/Clue (1985)/Clue (1985).mkv',
        ),
        'local file /storage/emulated/0/Bask/downloads/Movies/Clue (1985)/Clue (1985).mkv',
      );
    });

    test('drops the query from a stream, because that is where the token is', () {
      // Anchor: this line exists to be pasted into a message when somebody
      // asks whether a download played locally, so it must not carry the
      // credential that would let the reader into the server.
      final line = PlaybackSourceResolver.describeSource(
        PlaybackSourceKind.remoteDirect,
        'http://10.0.0.5:32400/library/parts/12345/file.mkv?X-Plex-Token=supersecret&session=abc',
      );

      expect(line, 'direct stream http://10.0.0.5:32400/library/parts/12345/file.mkv');
      expect(line, isNot(contains('supersecret')));
      expect(line, isNot(contains('X-Plex-Token')));
    });

    test('names a transcode as a transcode', () {
      expect(
        PlaybackSourceResolver.describeSource(
          PlaybackSourceKind.remoteTranscode,
          'http://10.0.0.5:32400/video/:/transcode/universal/start.m3u8?X-Plex-Token=secret',
        ),
        'server transcode http://10.0.0.5:32400/video/:/transcode/universal/start.m3u8',
      );
    });

    test('says so when nothing resolved rather than printing null', () {
      expect(
        PlaybackSourceResolver.describeSource(PlaybackSourceKind.remoteDirect, null),
        'direct stream (no target resolved)',
      );
    });
  });
}
