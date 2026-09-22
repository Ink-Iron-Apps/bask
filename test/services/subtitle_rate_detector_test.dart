import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_rate_detector.dart';
import 'package:plezy/services/subtitle_timing.dart';

const int _ninetyMinutes = 90 * 60 * 1000;

SubtitleSpan _span(int lastEndMs, {int events = 800}) =>
    SubtitleSpan(firstStartMs: 3000, lastEndMs: lastEndMs, eventCount: events);

void main() {
  group('parseSubtitleSpan', () {
    test('reads SubRip timings', () {
      const srt = '''
1
00:00:12,500 --> 00:00:15,000
First line

2
01:29:58,250 --> 01:29:59,750
Last line
''';

      final span = parseSubtitleSpan(srt);

      expect(span!.firstStartMs, 12500);
      expect(span.lastEndMs, 5399750);
      expect(span.eventCount, 2);
    });

    test('reads WebVTT, which writes the fraction with a dot', () {
      const vtt = '''
WEBVTT

00:00:01.000 --> 00:00:04.000
Hello
''';

      expect(parseSubtitleSpan(vtt)!.lastEndMs, 4000);
    });

    test('reads SubStation Alpha dialogue lines, in centiseconds', () {
      const ass = '''
[Events]
Format: Layer, Start, End, Style, Name
Dialogue: 0,0:00:05.25,0:00:07.50,Default,,0,0,0,,Hello
Dialogue: 0,1:29:00.00,1:29:02.00,Default,,0,0,0,,Bye
''';

      final span = parseSubtitleSpan(ass);

      expect(span!.firstStartMs, 5250);
      expect(span.lastEndMs, 5342000);
      expect(span.eventCount, 2);
    });

    test('returns null for something that is not a subtitle file', () {
      expect(parseSubtitleSpan('<html><body>404</body></html>'), isNull);
      expect(parseSubtitleSpan(''), isNull);
    });
  });

  group('detectSubtitleRate', () {
    test('corrects subtitles that run past the end of the video', () {
      // 23.976 fps subtitles over a 25 fps transfer: the file covers 4.27%
      // more time than the video has. Nothing innocent looks like this.
      final span = _span((_ninetyMinutes * (25 / 23.976)).round());

      final suggestion = detectSubtitleRate(span: span, videoDurationMs: _ninetyMinutes);

      expect(suggestion!.certain, isTrue);
      expect(suggestion.speed, closeTo(25 / 23.976, 0.001));
    });

    test('leaves subtitles that stop early alone unless asked', () {
      // Same shape as a film whose credits carry no dialogue.
      final span = _span((_ninetyMinutes * (23.976 / 25)).round());

      expect(detectSubtitleRate(span: span, videoDurationMs: _ninetyMinutes), isNull);
    });

    test('corrects the early case when told to, and says it is not certain', () {
      final span = _span((_ninetyMinutes * (23.976 / 25)).round());

      final suggestion = detectSubtitleRate(span: span, videoDurationMs: _ninetyMinutes, allowAmbiguous: true);

      expect(suggestion!.certain, isFalse);
      expect(suggestion.speed, closeTo(23.976 / 25, 0.001));
    });

    test('ignores a gap that matches no known conversion', () {
      // Three minutes of silent credits on a 90 minute film: short, but not
      // by any frame-rate ratio.
      final span = _span(_ninetyMinutes - 3 * 60 * 1000);

      expect(detectSubtitleRate(span: span, videoDurationMs: _ninetyMinutes, allowAmbiguous: true), isNull);
    });

    test('leaves a correctly timed file alone', () {
      expect(detectSubtitleRate(span: _span(_ninetyMinutes - 2000), videoDurationMs: _ninetyMinutes), isNull);
    });

    test('says nothing about a file with a handful of events', () {
      // Forced signs, a single caption: no evidence about the whole runtime.
      final span = _span((_ninetyMinutes * (25 / 23.976)).round(), events: 4);

      expect(detectSubtitleRate(span: span, videoDurationMs: _ninetyMinutes), isNull);
    });

    test('needs a video duration to measure against', () {
      expect(detectSubtitleRate(span: _span(_ninetyMinutes), videoDurationMs: 0), isNull);
    });
  });

  test('clamps to the range the rest of the app accepts', () {
    expect(clampSubtitleSpeed(9.0), 2.0);
    expect(clampSubtitleSpeed(0.1), 0.5);
    expect(clampSubtitleSpeed(1.0427), closeTo(1.0427, 0.0001));
  });
}
