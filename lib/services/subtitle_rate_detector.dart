import 'dart:math' as math;

import 'subtitle_timing.dart';

/// A correction to mpv's `sub-speed`, and how sure we are of it.
class SubtitleRateSuggestion {
  const SubtitleRateSuggestion({required this.speed, required this.certain, required this.measuredRatio});

  /// What to set `sub-speed` to. Above 1 runs the subtitles faster.
  final double speed;

  /// True when the evidence rules out the innocent explanation.
  ///
  /// Subtitles that run past the end of the video are mistimed and nothing
  /// else; subtitles that stop early may simply have nothing to say over the
  /// credits. Only the first case is safe to apply without being asked.
  final bool certain;

  /// Subtitle span over video duration, kept for the log.
  final double measuredRatio;
}

/// Frame-rate conversions that actually happen to subtitle files.
///
/// A PAL transfer runs 25/23.976 faster than the film it came from, so a
/// subtitle authored against one and played over the other drifts by 4.27% —
/// eight seconds by three minutes, over two by fifty. 24 → 25 is the same
/// story a hair smaller, and 30 → 29.97 is the NTSC pulldown pair.
const List<double> _knownConversions = [25 / 23.976, 25 / 24, 30 / 29.97];

/// Nothing beyond half a percent of a known conversion is treated as one.
///
/// Credits, a missing final line, a stray comment event: all move the measured
/// ratio a little. The conversions sit 4% and 0.1% away from 1, so a tight
/// window is what keeps "ends a bit early" from being read as "authored at
/// another frame rate".
const double _snapTolerance = 0.005;

/// Work out whether a subtitle file is timed for a different frame rate.
///
/// [span] is the subtitle's own extent, [videoDurationMs] the video's. The
/// ratio between them is the whole signal, which makes the short direction
/// ambiguous: a subtitle that ends 4% early may be mistimed, or may just stop
/// before the credits roll. [allowAmbiguous] decides whether to act on that
/// case — on, it is corrected whenever the ratio lands on a known conversion;
/// off, only subtitles running past the end of the video are touched, which
/// no correctly timed file ever does.
///
/// Returns null when there is nothing to fix or nothing to go on.
SubtitleRateSuggestion? detectSubtitleRate({
  required SubtitleSpan span,
  required int videoDurationMs,
  bool allowAmbiguous = false,
  int minimumEvents = 20,
}) {
  if (videoDurationMs <= 0 || span.lastEndMs <= 0) return null;
  // A handful of events — forced signs, a single caption — say nothing about
  // the shape of the whole file.
  if (span.eventCount < minimumEvents) return null;

  final ratio = span.lastEndMs / videoDurationMs;
  final snapped = _snapToConversion(ratio);

  if (ratio > 1 + _snapTolerance) {
    // Past the end of the video: mistimed, whatever the cause. Correct by the
    // measured amount when it matches nothing known, since the alternative is
    // leaving lines that can never be shown.
    return SubtitleRateSuggestion(speed: snapped ?? ratio, certain: true, measuredRatio: ratio);
  }

  if (!allowAmbiguous || snapped == null || snapped >= 1) return null;

  // Shorter than the video by exactly one of the known conversions. Could be
  // the credits; the caller asked for the benefit of the doubt.
  return SubtitleRateSuggestion(speed: snapped, certain: false, measuredRatio: ratio);
}

/// The known conversion nearest [ratio], as a `sub-speed`, or null.
///
/// Subtitles authored fast need slowing, so the reciprocal is what goes to
/// mpv — the direction the measured ratio already points in.
double? _snapToConversion(double ratio) {
  for (final conversion in _knownConversions) {
    for (final candidate in [conversion, 1 / conversion]) {
      if ((ratio - candidate).abs() <= _snapTolerance) return candidate;
    }
  }
  return null;
}

/// Whether two speeds are the same setting, given how they are stored.
bool sameSubtitleSpeed(double a, double b) => (a - b).abs() < 0.0005;

/// Clamp to the range the rest of the app accepts for `sub-speed`.
double clampSubtitleSpeed(double speed, {double min = 0.5, double max = 2.0}) => math.min(math.max(speed, min), max);
