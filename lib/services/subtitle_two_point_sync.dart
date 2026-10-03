/// One place where a subtitle line and the picture are known to belong
/// together.
class SubtitleSyncAnchor {
  const SubtitleSyncAnchor({required this.subtitleMs, required this.actualMs});

  /// Timestamp the subtitle file gives the line, as authored.
  final int subtitleMs;

  /// Where the viewer says that line actually belongs.
  final int actualMs;
}

/// A correction to apply: mpv's `sub-speed` and `sub-delay`.
class SubtitleSyncSolution {
  const SubtitleSyncSolution({required this.speed, required this.delayMs});

  final double speed;
  final int delayMs;

  /// Where this correction puts a line authored at [subtitleMs].
  ///
  /// The inverse of what the solver fits: mpv shows a line at
  /// `authored / speed + delay`, so this is what the viewer will see.
  int displayedTime(int subtitleMs) => (subtitleMs / speed).round() + delayMs;
}

/// Why a pair of anchors could not be turned into a correction.
enum SubtitleSyncRejection {
  /// The two marks are too close together in time.
  tooClose,

  /// The implied rate is outside anything a frame-rate mismatch produces, so
  /// one of the marks was almost certainly on the wrong line.
  implausibleRate,

  /// The implied shift is beyond what the player will hold.
  implausibleDelay,
}

/// Solve a subtitle correction from two marked lines.
///
/// A constant offset cannot fix a file authored against another frame rate,
/// and a frame-rate ratio cannot fix a file that is simply shifted — a
/// subtitle for a release with a different intro length is both. Two points
/// determine both at once, with no guessing about the cause: the viewer marks
/// a line near the start and a line near the end, and the line through them is
/// the answer.
///
/// mpv applies these as `displayed = authored / speed + delay`, which is the
/// direction the fork's existing rate control already uses — 25 fps subtitles
/// over a 23.976 fps film are corrected with a speed below one.
///
/// Returns null, with [rejection] set, rather than applying arithmetic to
/// marks that cannot be right: a pair seconds apart turns ordinary reaction
/// time into a large rate error, and a wildly implausible rate means one mark
/// landed on the wrong line.
({SubtitleSyncSolution? solution, SubtitleSyncRejection? rejection}) solveSubtitleSync(
  SubtitleSyncAnchor first,
  SubtitleSyncAnchor second, {
  Duration minimumSeparation = const Duration(minutes: 1),
  double minimumSpeed = 0.5,
  double maximumSpeed = 2.0,
  Duration maximumDelay = const Duration(seconds: 60),
}) {
  final early = first.actualMs <= second.actualMs ? first : second;
  final late = first.actualMs <= second.actualMs ? second : first;

  final actualSpan = late.actualMs - early.actualMs;
  final subtitleSpan = late.subtitleMs - early.subtitleMs;
  if (actualSpan < minimumSeparation.inMilliseconds || subtitleSpan <= 0) {
    return (solution: null, rejection: SubtitleSyncRejection.tooClose);
  }

  final speed = subtitleSpan / actualSpan;
  if (speed < minimumSpeed || speed > maximumSpeed) {
    return (solution: null, rejection: SubtitleSyncRejection.implausibleRate);
  }

  // Solved from the earlier anchor, because an error there is the one the
  // viewer notices first.
  final delayMs = (early.actualMs - early.subtitleMs / speed).round();
  if (delayMs.abs() > maximumDelay.inMilliseconds) {
    return (solution: null, rejection: SubtitleSyncRejection.implausibleDelay);
  }

  return (solution: SubtitleSyncSolution(speed: speed, delayMs: delayMs), rejection: null);
}
