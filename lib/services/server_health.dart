import '../media/media_backend.dart';

/// How traffic to a server is reaching it.
enum ServerLinkKind {
  /// A LAN address: fastest, and the only one that does not leave the house.
  local,

  /// The server's own public address, direct.
  remote,

  /// Plex's relay, which carries the stream through plex.tv and is capped at
  /// about 2 Mbps. Playback that is suddenly soft or stuttering while the
  /// server looks "online" is usually this.
  relay,

  /// A MediaBrowser server, or a Plex endpoint the account's connection list
  /// does not describe — a manually entered reverse proxy, for example.
  unknown,
}

/// One server as the app currently sees it.
///
/// Every field is something the app already decided and then kept to itself:
/// which endpoint won the race, whether that endpoint is a relay, whether the
/// token was rejected, whether the server is hidden from this profile. When
/// playback is poor, the difference between "my connection is bad" and "this
/// is going through the relay" is the whole diagnosis, and until now there was
/// no way to tell them apart from inside the app.
class ServerHealth {
  const ServerHealth({
    required this.serverId,
    required this.name,
    required this.backend,
    required this.online,
    required this.visible,
    required this.authError,
    required this.link,
    this.endpoint,
    this.relayEscapePending = false,
    this.latency,
  });

  final String serverId;
  final String name;
  final MediaBackend backend;

  /// Whether the last health check or connect attempt succeeded.
  final bool online;

  /// Whether this profile is allowed to see the server at all.
  final bool visible;

  /// The server answered, but rejected the token.
  final bool authError;

  final ServerLinkKind link;

  /// Base URL in use, with no credentials in it.
  final String? endpoint;

  /// A relay escape is scheduled: the app is waiting to retry a better
  /// endpoint rather than leaving the session on the relay.
  final bool relayEscapePending;

  /// Round trip of the last measured probe, when one has been taken.
  final Duration? latency;

  /// Whether this server is worth drawing attention to.
  ///
  /// A relay is the case that looks like a broken connection and is not, so it
  /// counts; an auth error and an offline server are plainly wrong. A hidden
  /// server is a choice, not a fault.
  bool get needsAttention => authError || (visible && !online) || link == ServerLinkKind.relay;

  ServerHealth withLatency(Duration? value) => ServerHealth(
    serverId: serverId,
    name: name,
    backend: backend,
    online: online,
    visible: visible,
    authError: authError,
    link: link,
    endpoint: endpoint,
    relayEscapePending: relayEscapePending,
    latency: value,
  );
}

/// Strips anything secret from an endpoint before it is shown or logged.
///
/// A Plex base URL carries no token, but a manually entered one can, and this
/// is a screen people photograph to ask for help.
String? redactEndpoint(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  if (!uri.hasQuery && uri.userInfo.isEmpty) return url;
  // Rebuilt rather than replaced: Uri.replace with an empty query leaves a
  // bare "?" behind, which reads as a truncated URL.
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: uri.path).toString();
}
