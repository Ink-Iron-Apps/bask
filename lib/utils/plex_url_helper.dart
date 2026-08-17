/// Extension methods for appending Plex authentication tokens to URLs.
extension PlexUrlExtension on String {
  /// Appends a Plex authentication token to this URL string.
  ///
  /// Automatically determines whether to use '?' or '&' as the separator
  /// based on whether the URL already contains query parameters.
  ///
  /// If [token] is null or empty, returns the URL unchanged.
  ///
  /// Example:
  /// ```dart
  /// final url = '/library/metadata/123'.withPlexToken('abc123');
  /// // Result: '/library/metadata/123?X-Plex-Token=abc123'
  ///
  /// final urlWithParams = '/library/metadata/123?type=1'.withPlexToken('abc123');
  /// // Result: '/library/metadata/123?type=1&X-Plex-Token=abc123'
  /// ```
  String withPlexToken(String? token) {
    if (token == null || token.isEmpty) return this;
    final separator = contains('?') ? '&' : '?';
    return '$this${separator}X-Plex-Token=$token';
  }

  /// Marks a part URL as a file download rather than playback.
  ///
  /// Without `download=1` the server runs its streaming-decision path and opens
  /// a playback session per request ("Attempting to create AdHoc dp session").
  /// It keeps one such session per client, so a second concurrent download
  /// terminates the first — the server logs "Terminated session … with reason
  /// Client stopped playback" inside the very request that starts the next one,
  /// and the client sees the transfer die with "unexpected end of stream".
  /// Downloads run in a round-robin of mutual eviction and never finish.
  ///
  /// With the flag the part is served as a plain file, with no session
  /// accounting and nothing to evict, so downloads can run concurrently.
  String asPlexDownload() {
    if (contains('download=1')) return this;
    final separator = contains('?') ? '&' : '?';
    return '$this${separator}download=1';
  }

  /// Appends a base URL and Plex authentication token to this path string.
  ///
  /// If [token] is null or empty, returns the URL without a token parameter.
  ///
  /// Example:
  /// ```dart
  /// final fullUrl = '/library/metadata/123'.toPlexUrl('http://server:32400', 'abc123');
  /// // Result: 'http://server:32400/library/metadata/123?X-Plex-Token=abc123'
  /// ```
  String toPlexUrl(String baseUrl, String? token) {
    return '$baseUrl$this'.withPlexToken(token);
  }
}
