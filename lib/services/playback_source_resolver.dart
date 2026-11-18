import 'package:flutter/foundation.dart';

import '../database/app_database.dart';
import '../media/ids.dart';
import '../media/media_backend.dart';
import '../media/media_server_client.dart';
import '../utils/app_logger.dart';
import 'multi_server_manager.dart';
import 'playback_context.dart';
import 'playback_initialization_service.dart';

class PlaybackSourceResolver {
  final MultiServerManager serverManager;
  final AppDatabase database;

  const PlaybackSourceResolver({required this.serverManager, required this.database});

  /// Always prefers a downloaded copy of the requested version.
  ///
  /// The quality preset used to gate this, so a device set to anything but
  /// Original streamed a file it already had. A preset is a cap on what to
  /// ask the server for, and local playback asks for nothing: it costs no
  /// bandwidth, needs no transcode, and works when the server does not. The
  /// version match is still strict — an explicitly requested version that was
  /// never downloaded streams (issue #1440) — so this only ever substitutes
  /// the same file the user would have been sent.
  Future<PlaybackContext> resolve(PlaybackInitializationOptions options, {required bool offlineLibraryMode}) async {
    final metadata = options.metadata;
    final reportingClient = _playbackClient(serverIdOrNull(metadata.serverId), offlineLibraryMode: offlineLibraryMode);
    final service = PlaybackInitializationService(client: reportingClient, database: database);
    final result = await service.getPlaybackData(options, preferOffline: true, requireOffline: offlineLibraryMode);

    final sourceKind = result.usesLocalMedia
        ? PlaybackSourceKind.localFile
        : result.isTranscoding
        ? PlaybackSourceKind.remoteTranscode
        : PlaybackSourceKind.remoteDirect;
    final reportingMode = _reportingMode(
      sourceKind: sourceKind,
      client: reportingClient,
      offlineLibraryMode: offlineLibraryMode,
    );

    // One line per play naming what is actually about to be opened.
    //
    // There was no way to tell a local file from a stream after the fact: a
    // 7 MB log of a successful playback of a downloaded film carried nothing
    // about its source, so answering "did that play from the device or from
    // the server?" meant physically pulling the device off the network. That
    // is a silly price for a question this cheap to answer.
    //
    // The query string is dropped rather than logged: a streaming URL carries
    // the access token, and a log is a thing people paste into messages.
    appLogger.i('Playback source: ${describeSource(sourceKind, result.videoUrl)}');

    return PlaybackContext(
      metadata: metadata,
      result: result,
      sourceKind: sourceKind,
      reportingMode: reportingMode,
      reportingClient: reportingClient,
      streamHeaders: _streamHeaders(
        client: reportingClient,
        sourceKind: sourceKind,
        sessionIdentifier: options.sessionIdentifier,
      ),
    );
  }

  /// A short, safe description of what playback is about to open.
  @visibleForTesting
  static String describeSource(PlaybackSourceKind kind, String? videoUrl) {
    final label = switch (kind) {
      PlaybackSourceKind.localFile => 'local file',
      PlaybackSourceKind.remoteDirect => 'direct stream',
      PlaybackSourceKind.remoteTranscode => 'server transcode',
    };
    if (videoUrl == null || videoUrl.isEmpty) return '$label (no target resolved)';

    if (kind == PlaybackSourceKind.localFile) {
      // A path is not a secret, and the whole point of the line is to show
      // which file on which volume answered.
      return '$label $videoUrl';
    }

    final parsed = Uri.tryParse(videoUrl);
    if (parsed == null) return label;
    // Rebuilt from the parts worth keeping rather than cleared in place:
    // clearing the query and fragment leaves their punctuation behind, so the
    // line ended in a bare "?#". Everything that identifies the viewer lives
    // in the query, and nothing in the path needs hiding.
    final redacted = Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: parsed.path,
    );
    return '$label $redacted';
  }

  Map<String, String>? _streamHeaders({
    required MediaServerClient? client,
    required PlaybackSourceKind sourceKind,
    String? sessionIdentifier,
  }) {
    if (client == null || sourceKind == PlaybackSourceKind.localFile) return null;

    final headers = Map<String, String>.from(client.streamHeaders);
    if (client.backend == MediaBackend.plex && sessionIdentifier != null) {
      headers['X-Plex-Session-Identifier'] = sessionIdentifier;
    }
    return headers;
  }

  MediaServerClient? _playbackClient(ServerId? serverId, {required bool offlineLibraryMode}) {
    if (serverId == null ||
        !serverManager.isServerVisible(serverId) ||
        serverManager.authErrorServerIds.contains(serverId)) {
      return null;
    }
    final client = serverManager.getClient(serverId);
    if (offlineLibraryMode && !serverManager.isClientOnline(serverId)) return null;
    return client;
  }

  PlaybackReportingMode _reportingMode({
    required PlaybackSourceKind sourceKind,
    required MediaServerClient? client,
    required bool offlineLibraryMode,
  }) {
    if (client != null) {
      return sourceKind == PlaybackSourceKind.localFile
          ? PlaybackReportingMode.onlineWithOfflineFallback
          : PlaybackReportingMode.online;
    }
    if (sourceKind == PlaybackSourceKind.localFile || offlineLibraryMode) return PlaybackReportingMode.offlineQueue;
    return PlaybackReportingMode.disabled;
  }
}
