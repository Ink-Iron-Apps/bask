import 'dart:convert';

/// Where a subtitle file's events start and end.
class SubtitleSpan {
  const SubtitleSpan({required this.firstStartMs, required this.lastEndMs, required this.eventCount});

  final int firstStartMs;
  final int lastEndMs;
  final int eventCount;
}

/// Reads the timestamps out of a subtitle file, and nothing else.
///
/// Only the span matters here: where the first line appears and where the last
/// one leaves. That is enough to tell a subtitle authored against one frame
/// rate from one authored against another, and it avoids carrying a subtitle
/// parser around for text nobody displays from this path.
///
/// Handles the three formats a server hands out as text — SubRip, WebVTT and
/// SubStation Alpha. Anything else returns null rather than a guess.
SubtitleSpan? parseSubtitleSpan(String content) {
  if (content.isEmpty) return null;

  final events = <({int start, int end})>[];
  for (final line in const LineSplitter().convert(content)) {
    final event = _parseSubRipOrVtt(line) ?? _parseSubStationAlpha(line);
    if (event != null) events.add(event);
  }
  if (events.isEmpty) return null;

  var firstStart = events.first.start;
  var lastEnd = events.first.end;
  for (final event in events) {
    if (event.start < firstStart) firstStart = event.start;
    if (event.end > lastEnd) lastEnd = event.end;
  }

  return SubtitleSpan(firstStartMs: firstStart, lastEndMs: lastEnd, eventCount: events.length);
}

/// `00:01:02,500 --> 00:01:05,000`, with either separator: WebVTT writes the
/// fraction with a dot and may leave the hour off entirely.
final RegExp _subRipPattern = RegExp(
  r'(\d{1,2}):(\d{2}):(\d{2})[.,](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[.,](\d{1,3})',
);

/// `Dialogue: 0,0:01:02.50,0:01:05.00,Default,...` — centiseconds, one-digit
/// hour, and the same line carries both ends.
final RegExp _assPattern = RegExp(
  r'^(?:Dialogue|Comment)\s*:[^,]*,\s*(\d):(\d{2}):(\d{2})[.,](\d{2})\s*,\s*(\d):(\d{2}):(\d{2})[.,](\d{2})\s*,',
);

({int start, int end})? _parseSubRipOrVtt(String line) {
  final match = _subRipPattern.firstMatch(line);
  if (match == null) return null;
  return (
    start: _ms(match.group(1)!, match.group(2)!, match.group(3)!, match.group(4)!.padRight(3, '0')),
    end: _ms(match.group(5)!, match.group(6)!, match.group(7)!, match.group(8)!.padRight(3, '0')),
  );
}

({int start, int end})? _parseSubStationAlpha(String line) {
  final match = _assPattern.firstMatch(line);
  if (match == null) return null;
  return (
    start: _ms(match.group(1)!, match.group(2)!, match.group(3)!, '${match.group(4)!}0'),
    end: _ms(match.group(5)!, match.group(6)!, match.group(7)!, '${match.group(8)!}0'),
  );
}

int _ms(String hours, String minutes, String seconds, String millis) =>
    int.parse(hours) * 3600000 + int.parse(minutes) * 60000 + int.parse(seconds) * 1000 + int.parse(millis);
