import 'media_backend.dart';
import 'ids.dart';

/// How a session's video and audio are reaching the client.
enum StreamMethod {
  /// The original file, untouched.
  directPlay,

  /// Original streams, remuxed into a different container.
  directStream,

  /// Re-encoded by the server.
  transcode,
}

/// What the server is doing to one stream of a session.
///
/// Kept separate per track because the common case is a mixed session — video
/// direct play with the audio transcoded for a client that cannot decode the
/// original codec — and reporting the session as simply "transcoding" hides
/// which half is costing the CPU.
class StreamDecision {
  final StreamMethod method;

  /// Source codec, as the server names it.
  final String? sourceCodec;

  /// Codec being delivered, when it differs from [sourceCodec].
  final String? targetCodec;

  const StreamDecision({required this.method, this.sourceCodec, this.targetCodec});
}

/// One active playback session on a media server.
///
/// Backend-neutral: a Plex `/status/sessions` entry and a Jellyfin `/Sessions`
/// entry both land here, including the fields that only one of them reports.
class PlaybackSession {
  final ServerId serverId;
  final MediaBackend backend;

  /// The id commands take. Plex's `Session.id` — deliberately not
  /// `sessionKey`, which identifies the row and is rejected by the terminate
  /// endpoint. Jellyfin's `Id`.
  final String sessionId;

  final String? userName;
  final String? userId;

  /// The device, as the server sees it ("Living Room TV").
  final String? deviceName;

  /// The client application ("Plex for Android", "Jellyfin Web").
  final String? clientName;

  final String? platform;

  /// Title of what is playing, already resolved for an episode: the episode's
  /// own title rather than the show's.
  final String? title;

  /// Context line under [title] — the show name, or the album artist.
  final String? subtitle;

  /// Season and episode numbers when the item is an episode, left for the UI
  /// to format — the clients return data, the screen owns presentation.
  final int? seasonIndex;
  final int? episodeIndex;

  /// Artwork path on [serverId], to be resolved through that server's client.
  final String? thumbPath;

  final String? itemId;

  final int? positionMs;
  final int? durationMs;
  final bool isPaused;

  final StreamDecision? video;
  final StreamDecision? audio;

  /// Why the server chose to transcode, when it says.
  final String? transcodeReason;

  /// Delivery bandwidth in kbps, as reported.
  final int? bandwidthKbps;

  /// True when the server reports the client as outside the local network.
  final bool? isRemote;

  /// Whether this session can be stopped.
  ///
  /// Plex terminates server-side and so can always stop a session it lists.
  /// Jellyfin asks the *client* to stop, so it can only stop a session whose
  /// `SupportedCommands` includes the playstate commands — otherwise the call
  /// returns 204 and nothing happens, which is worse than no button.
  final bool canStop;

  /// Whether a message can be delivered without ending playback.
  ///
  /// Jellyfin only. Plex has no standalone message endpoint: there the text
  /// rides the termination as its reason, so [canStop] carries it instead.
  final bool canMessage;

  const PlaybackSession({
    required this.serverId,
    required this.backend,
    required this.sessionId,
    this.userName,
    this.userId,
    this.deviceName,
    this.clientName,
    this.platform,
    this.title,
    this.subtitle,
    this.seasonIndex,
    this.episodeIndex,
    this.thumbPath,
    this.itemId,
    this.positionMs,
    this.durationMs,
    this.isPaused = false,
    this.video,
    this.audio,
    this.transcodeReason,
    this.bandwidthKbps,
    this.isRemote,
    this.canStop = false,
    this.canMessage = false,
  });

  /// Stable identity across refreshes, for list keys and focus retention.
  String get globalKey => '${serverId.value}:$sessionId';

  /// 0..1 through the item, or null when either end is unknown.
  double? get progress {
    final position = positionMs;
    final duration = durationMs;
    if (position == null || duration == null || duration <= 0) return null;
    return (position / duration).clamp(0.0, 1.0);
  }

  /// The heaviest thing the server is doing for this session, which is what a
  /// one-line summary should lead with.
  StreamMethod get effectiveMethod {
    final methods = [?video?.method, ?audio?.method];
    if (methods.contains(StreamMethod.transcode)) return StreamMethod.transcode;
    if (methods.contains(StreamMethod.directStream)) return StreamMethod.directStream;
    return StreamMethod.directPlay;
  }
}
