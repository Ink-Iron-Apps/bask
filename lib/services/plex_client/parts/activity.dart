part of '../../plex_client.dart';

/// `/status/sessions` and the admin actions on it.
///
/// Neither endpoint appears in Plex's published API reference; both are what
/// the server's own dashboard and Tautulli use, and the shapes here were taken
/// from those. Treat an unexpected body as "no sessions" rather than an error:
/// the screen polls, and one malformed response should not replace a working
/// list with a failure.
mixin _PlexActivityMethods on _PlexClientInternals implements MediaServerActivityClient {
  /// Plex sends numbers as JSON ints, but a few fields arrive as strings
  /// depending on server version, so coerce rather than cast.
  static int? _plexInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };

  Future<List<PlaybackSession>> _getActiveSessions() async {
    final response = await _getWithFailover('/status/sessions');
    throwIfHttpError(response);

    final data = response.data;
    if (data is! Map) return const [];
    final container = data['MediaContainer'];
    if (container is! Map) return const [];

    final sessions = <PlaybackSession>[];
    for (final key in const ['Metadata', 'Video', 'Track', 'Photo']) {
      final rows = container[key];
      if (rows is! List) continue;
      for (final row in rows) {
        if (row is! Map) continue;
        final session = _parsePlexSession(row.cast<String, dynamic>());
        if (session != null) sessions.add(session);
      }
    }
    return sessions;
  }

  PlaybackSession? _parsePlexSession(Map<String, dynamic> row) {
    // `Session.id` is what terminate accepts. `sessionKey` identifies the row
    // in this response and is rejected, so a session without the former
    // cannot be acted on and is not worth listing.
    final session = row['Session'];
    final sessionId = session is Map ? session['id']?.toString() : null;
    if (sessionId == null || sessionId.isEmpty) return null;

    final player = row['Player'] is Map ? (row['Player'] as Map) : const {};
    final user = row['User'] is Map ? (row['User'] as Map) : const {};

    final type = row['type']?.toString();
    final isEpisode = type == 'episode';

    // Plex reports the decision per stream inside the first Media/Part.
    StreamDecision? video;
    StreamDecision? audio;
    String? transcodeReason;
    final media = row['Media'];
    if (media is List && media.isNotEmpty && media.first is Map) {
      final parts = (media.first as Map)['Part'];
      if (parts is List && parts.isNotEmpty && parts.first is Map) {
        final part = parts.first as Map;
        final streams = part['Stream'];
        if (streams is List) {
          for (final stream in streams) {
            if (stream is! Map) continue;
            // streamType 1 = video, 2 = audio.
            final streamType = _plexInt(stream['streamType']);
            final decision = _plexStreamDecision(stream);
            if (streamType == 1) {
              video ??= decision;
            } else if (streamType == 2) {
              audio ??= decision;
            }
          }
        }
      }
    }
    final transcode = row['TranscodeSession'];
    if (transcode is Map) {
      transcodeReason = transcode['transcodeHwRequested'] == true
          ? transcode['videoDecision']?.toString()
          : transcode['transcodeReason']?.toString() ?? transcode['videoDecision']?.toString();
    }

    return PlaybackSession(
      serverId: serverId,
      backend: MediaBackend.plex,
      sessionId: sessionId,
      userName: user['title']?.toString(),
      userId: user['id']?.toString(),
      deviceName: player['device']?.toString() ?? player['title']?.toString(),
      clientName: player['product']?.toString(),
      platform: player['platform']?.toString(),
      title: row['title']?.toString(),
      subtitle: isEpisode ? row['grandparentTitle']?.toString() : row['parentTitle']?.toString(),
      seasonIndex: isEpisode ? _plexInt(row['parentIndex']) : null,
      episodeIndex: isEpisode ? _plexInt(row['index']) : null,
      thumbPath: (row['thumb'] ?? row['grandparentThumb'] ?? row['parentThumb'])?.toString(),
      itemId: row['ratingKey']?.toString(),
      positionMs: _plexInt(row['viewOffset']),
      durationMs: _plexInt(row['duration']),
      isPaused: player['state']?.toString() == 'paused',
      video: video,
      audio: audio,
      transcodeReason: transcodeReason,
      bandwidthKbps: _plexInt(session is Map ? session['bandwidth'] : null),
      isRemote: player['local'] == null ? null : player['local'] != true,
      // The server kills the stream itself, so this never depends on what the
      // client supports.
      canStop: true,
      // Plex has no standalone message endpoint; the text rides terminate.
      canMessage: false,
    );
  }

  StreamDecision _plexStreamDecision(Map<dynamic, dynamic> stream) {
    final decision = stream['decision']?.toString();
    final method = switch (decision) {
      'transcode' => StreamMethod.transcode,
      'copy' => StreamMethod.directStream,
      _ => StreamMethod.directPlay,
    };
    return StreamDecision(
      method: method,
      sourceCodec: stream['codec']?.toString(),
      targetCodec: method == StreamMethod.transcode ? stream['decision']?.toString() : null,
    );
  }

  Future<void> _terminateSession(String sessionId, {String? reason}) async {
    final response = await _getWithFailover(
      '/status/sessions/terminate',
      queryParameters: {'sessionId': sessionId, if (reason != null && reason.isNotEmpty) 'reason': reason},
    );
    throwIfHttpError(response);
  }

  @override
  Future<List<PlaybackSession>> fetchActiveSessions() => _getActiveSessions();

  @override
  Future<void> stopSession(PlaybackSession session, {String? reason}) =>
      _terminateSession(session.sessionId, reason: reason);

  @override
  Future<void> messageSession(PlaybackSession session, {required String message, String? header}) async {
    // Plex exposes no standalone message endpoint; `canMessage` is false for
    // every Plex session, so nothing should reach this.
    throw UnsupportedError('Plex delivers a message as the reason on stopSession');
  }
}
