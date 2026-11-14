part of '../../jellyfin_client.dart';

/// `/Sessions` and the remote-control commands on it.
///
/// The asymmetry with Plex matters here. Plex terminates a stream inside the
/// server; Jellyfin only *asks* a client to stop, over the same channel the
/// client registered its capabilities on. A session that never registered
/// playstate support accepts the POST, answers 204, and keeps playing — so
/// support is read off `SupportedCommands` and the button is withheld rather
/// than offered and silently ignored.
mixin _JellyfinActivityMethods on _JellyfinClientInternals implements MediaServerActivityClient {
  /// How long a session may have been idle and still be listed. Jellyfin keeps
  /// signed-in sessions with no playback indefinitely, and "what is playing
  /// right now" should not list a TV someone turned off last week.
  static const _activeWithinSeconds = 960;

  Future<List<PlaybackSession>> _getActiveSessions() async {
    final response = await _http.get('/Sessions', queryParameters: {'activeWithinSeconds': '$_activeWithinSeconds'});
    throwIfHttpError(response);

    final data = response.data;
    if (data is! List) return const [];

    final sessions = <PlaybackSession>[];
    for (final row in data) {
      if (row is! Map) continue;
      final session = _parseJellyfinSession(row.cast<String, dynamic>());
      if (session != null) sessions.add(session);
    }
    return sessions;
  }

  PlaybackSession? _parseJellyfinSession(Map<String, dynamic> row) {
    final sessionId = row['Id']?.toString();
    if (sessionId == null || sessionId.isEmpty) return null;

    // Only sessions actually playing something belong on a "now playing"
    // screen; the rest are idle sign-ins.
    final item = row['NowPlayingItem'];
    if (item is! Map) return null;

    final playState = row['PlayState'] is Map ? (row['PlayState'] as Map) : const {};
    final transcoding = row['TranscodingInfo'] is Map ? (row['TranscodingInfo'] as Map) : null;

    final commands = row['SupportedCommands'];
    final supportsPlaystate =
        row['SupportsRemoteControl'] == true &&
        commands is List &&
        commands.any((c) => c.toString() == 'PlayState' || c.toString() == 'Stop');
    final supportsMessage =
        row['SupportsRemoteControl'] == true &&
        commands is List &&
        commands.any((c) => c.toString() == 'DisplayMessage');

    final isEpisode = item['Type']?.toString() == 'Episode';

    // Jellyfin reports one decision per stream inside TranscodingInfo: the
    // booleans say which halves are being re-encoded, so an absent
    // TranscodingInfo is a direct play of both.
    StreamDecision decisionFor({required bool isVideo}) {
      if (transcoding == null) {
        return StreamDecision(
          method: StreamMethod.directPlay,
          sourceCodec: (isVideo ? item['Container'] : null)?.toString(),
        );
      }
      final isTranscoding = (isVideo ? transcoding['IsVideoDirect'] : transcoding['IsAudioDirect']) != true;
      return StreamDecision(
        method: isTranscoding ? StreamMethod.transcode : StreamMethod.directStream,
        targetCodec: isTranscoding
            ? (isVideo ? transcoding['VideoCodec'] : transcoding['AudioCodec'])?.toString()
            : null,
      );
    }

    final transcodeReasons = transcoding?['TranscodeReasons'];

    return PlaybackSession(
      serverId: serverId,
      backend: MediaBackend.jellyfin,
      sessionId: sessionId,
      userName: row['UserName']?.toString(),
      userId: row['UserId']?.toString(),
      deviceName: row['DeviceName']?.toString(),
      clientName: row['Client']?.toString(),
      platform: row['ApplicationVersion']?.toString(),
      title: item['Name']?.toString(),
      subtitle: isEpisode ? item['SeriesName']?.toString() : item['Album']?.toString(),
      seasonIndex: isEpisode ? _jellyfinInt(item['ParentIndexNumber']) : null,
      episodeIndex: isEpisode ? _jellyfinInt(item['IndexNumber']) : null,
      thumbPath: item['Id']?.toString(),
      itemId: item['Id']?.toString(),
      positionMs: jellyfinTicksToMs(playState['PositionTicks']),
      durationMs: jellyfinTicksToMs(item['RunTimeTicks']),
      isPaused: playState['IsPaused'] == true,
      video: decisionFor(isVideo: true),
      audio: decisionFor(isVideo: false),
      transcodeReason: transcodeReasons is List
          ? (transcodeReasons.isEmpty ? null : transcodeReasons.map((r) => r.toString()).join(', '))
          : transcodeReasons?.toString(),
      bandwidthKbps: switch (transcoding?['Bitrate']) {
        final num bitrate => (bitrate / 1000).round(),
        _ => null,
      },
      // Left unknown deliberately: Jellyfin reports `RemoteEndPoint` as a bare
      // IP and says nothing about whether it is local. Classifying it would
      // mean guessing at private ranges, which is wrong behind any NAT or VPN —
      // and this app is reached over a tailnet, where every address is private
      // and almost none of it is the living room.
      isRemote: null,
      canStop: supportsPlaystate,
      canMessage: supportsMessage,
    );
  }

  static int? _jellyfinInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };

  @override
  Future<List<PlaybackSession>> fetchActiveSessions() => _getActiveSessions();

  @override
  Future<void> stopSession(PlaybackSession session, {String? reason}) async {
    // The message goes first and separately: Stop has no reason parameter, and
    // a message sent after the client stopped may never be shown.
    if (reason != null && reason.isNotEmpty && session.canMessage) {
      try {
        await messageSession(session, message: reason);
      } catch (e) {
        // A courtesy that must not stop the stop from happening.
        appLogger.w('Could not message session before stopping it', error: e);
      }
    }
    final response = await _http.post('/Sessions/${session.sessionId}/Playing/Stop');
    throwIfHttpError(response);
  }

  @override
  Future<void> messageSession(PlaybackSession session, {required String message, String? header}) async {
    final response = await _http.post(
      '/Sessions/${session.sessionId}/Message',
      body: {'Text': message, 'Header': ?header, 'TimeoutMs': 8000},
    );
    throwIfHttpError(response);
  }
}
