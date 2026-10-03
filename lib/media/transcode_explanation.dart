/// What forced a server-side transcode, in terms a viewer can act on.
enum TranscodeReasonKind {
  /// The video codec is not one this client said it could decode.
  videoCodec,

  /// The audio codec, which on a TV usually means a surround format the
  /// device cannot pass through.
  audioCodec,

  /// The file's container, not its streams.
  container,

  /// A bitrate cap — almost always the app's own quality preset rather than
  /// anything about the file.
  bitrate,

  /// Resolution above what the client advertised.
  resolution,

  /// A subtitle that has to be burned into the picture, which forces a
  /// re-encode of a stream that was otherwise fine.
  subtitleBurnIn,

  /// The server said something this build does not recognize.
  unknown,
}

/// Why the current stream is being transcoded rather than played as-is.
///
/// The app already receives this and throws it away: Plex answers a decision
/// request with prose explaining itself, MediaBrowser answers with a list of
/// machine-readable reasons. Without it, a hot server and a soft picture are a
/// mystery, and the most common cause — the app's own quality preset, set once
/// and forgotten — is invisible.
class TranscodeExplanation {
  const TranscodeExplanation({required this.reasons, this.serverText, this.playMethod});

  /// Normalized reasons, in the order the server gave them.
  final List<TranscodeReasonKind> reasons;

  /// What the server said, kept verbatim for the cases the mapping misses.
  final String? serverText;

  /// `DirectPlay`, `DirectStream` or `Transcode`, as the backend reports it.
  final String? playMethod;

  bool get isEmpty => reasons.isEmpty && (serverText == null || serverText!.isEmpty);

  /// True when the only thing forcing a transcode is a limit the app set.
  ///
  /// Worth separating because it is the one reason the viewer can lift from
  /// inside the app, in one tap, with no change to the file or the server.
  bool get causedOnlyByOurCap => reasons.isNotEmpty && reasons.every((reason) => reason == TranscodeReasonKind.bitrate);
}

/// Map MediaBrowser's `TranscodeReasons` onto [TranscodeReasonKind].
///
/// The names are stable API values, so matching them exactly is right; an
/// unrecognized one becomes [TranscodeReasonKind.unknown] rather than being
/// dropped, because "the server gave a reason we do not understand" is still
/// more use than silence.
List<TranscodeReasonKind> parseMediaBrowserTranscodeReasons(Iterable<String> reasons) {
  final out = <TranscodeReasonKind>[];
  for (final reason in reasons) {
    final kind = switch (reason) {
      'VideoCodecNotSupported' ||
      'VideoProfileNotSupported' ||
      'VideoLevelNotSupported' => TranscodeReasonKind.videoCodec,
      'AudioCodecNotSupported' ||
      'AudioChannelsNotSupported' ||
      'AudioProfileNotSupported' => TranscodeReasonKind.audioCodec,
      'ContainerNotSupported' || 'ContainerBitrateExceedsLimit' => TranscodeReasonKind.container,
      'VideoBitrateNotSupported' || 'AudioBitrateNotSupported' => TranscodeReasonKind.bitrate,
      'VideoResolutionNotSupported' || 'VideoFramerateNotSupported' => TranscodeReasonKind.resolution,
      'SubtitleCodecNotSupported' => TranscodeReasonKind.subtitleBurnIn,
      _ => TranscodeReasonKind.unknown,
    };
    if (!out.contains(kind)) out.add(kind);
  }
  return out;
}

/// Read reasons out of Plex's decision prose.
///
/// Plex explains itself in sentences — "Direct play not available because the
/// audio codec is not supported" — so this looks for the subject of the
/// complaint rather than trying to parse the grammar. The original text is
/// kept alongside, so a sentence this misses is still shown to the viewer.
List<TranscodeReasonKind> parsePlexDecisionText(String? text) {
  if (text == null || text.trim().isEmpty) return const [];
  final lower = text.toLowerCase();
  final out = <TranscodeReasonKind>[];

  void add(TranscodeReasonKind kind) {
    if (!out.contains(kind)) out.add(kind);
  }

  if (lower.contains('subtitle')) add(TranscodeReasonKind.subtitleBurnIn);
  if (lower.contains('audio')) add(TranscodeReasonKind.audioCodec);
  if (lower.contains('video codec') || lower.contains('codec is not supported')) add(TranscodeReasonKind.videoCodec);
  if (lower.contains('container')) add(TranscodeReasonKind.container);
  if (lower.contains('bitrate') || lower.contains('bandwidth')) add(TranscodeReasonKind.bitrate);
  if (lower.contains('resolution') || lower.contains('too large')) add(TranscodeReasonKind.resolution);

  // Said something, but nothing recognizable: better to report that the
  // server had a reason than to report none.
  if (out.isEmpty) add(TranscodeReasonKind.unknown);
  return out;
}

/// Pull the decision prose out of a Plex decision body.
///
/// Three fields carry it and any of them can be the informative one, so they
/// are joined rather than chosen between.
String? plexDecisionTextFrom(dynamic data) {
  if (data is! Map) return null;
  final container = data['MediaContainer'];
  final source = container is Map ? container : data;

  final parts = <String>[];
  for (final key in ['generalDecisionText', 'mdeDecisionText', 'transcodeDecisionText']) {
    final value = source[key];
    if (value is String && value.trim().isNotEmpty && !parts.contains(value.trim())) parts.add(value.trim());
  }
  return parts.isEmpty ? null : parts.join(' · ');
}
