import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_two_point_sync.dart';

void main() {
  test('recovers a pure frame-rate error', () {
    // 25 fps subtitles over a 23.976 fps film: the file's timestamps run
    // 4.27% short, so a line authored at 10:00 belongs at 10:25.6.
    const ratio = 23.976 / 25;
    final first = SubtitleSyncAnchor(subtitleMs: (60000 * ratio).round(), actualMs: 60000);
    final second = SubtitleSyncAnchor(subtitleMs: (3600000 * ratio).round(), actualMs: 3600000);

    final result = solveSubtitleSync(first, second);

    expect(result.rejection, isNull);
    expect(result.solution!.speed, closeTo(ratio, 0.001));
    expect(result.solution!.delayMs.abs(), lessThan(50));
  });

  test('recovers a pure shift', () {
    // A subtitle for a release with a longer intro: every line late by the
    // same four seconds, which no frame-rate ratio explains.
    const shift = 4000;
    const first = SubtitleSyncAnchor(subtitleMs: 120000, actualMs: 120000 + shift);
    const second = SubtitleSyncAnchor(subtitleMs: 2400000, actualMs: 2400000 + shift);

    final result = solveSubtitleSync(first, second);

    expect(result.solution!.speed, closeTo(1.0, 0.001));
    expect(result.solution!.delayMs, closeTo(shift, 50));
  });

  test('recovers a shift and a rate error together', () {
    // The case neither existing control could fix on its own.
    const ratio = 0.96;
    const shift = -2500;
    SubtitleSyncAnchor at(int actualMs) =>
        SubtitleSyncAnchor(subtitleMs: ((actualMs - shift) * ratio).round(), actualMs: actualMs);

    final result = solveSubtitleSync(at(90000), at(4500000));

    expect(result.solution!.speed, closeTo(ratio, 0.001));
    expect(result.solution!.delayMs, closeTo(shift, 60));
    // What the viewer will actually see, end to end.
    expect(displayedSubtitleTime(result.solution!, ((4500000 - shift) * ratio).round()), closeTo(4500000, 100));
  });

  test('marks given in either order solve the same', () {
    const early = SubtitleSyncAnchor(subtitleMs: 60000, actualMs: 62000);
    const late = SubtitleSyncAnchor(subtitleMs: 1800000, actualMs: 1802000);

    final forwards = solveSubtitleSync(early, late).solution!;
    final backwards = solveSubtitleSync(late, early).solution!;

    expect(backwards.speed, closeTo(forwards.speed, 0.0001));
    expect(backwards.delayMs, forwards.delayMs);
  });

  test('refuses marks too close to separate rate from reaction time', () {
    // Twenty seconds apart, and a second of human lag reads as a 5% rate
    // error that would wreck the rest of the film.
    const first = SubtitleSyncAnchor(subtitleMs: 60000, actualMs: 60000);
    const second = SubtitleSyncAnchor(subtitleMs: 80000, actualMs: 81000);

    final result = solveSubtitleSync(first, second);

    expect(result.solution, isNull);
    expect(result.rejection, SubtitleSyncRejection.tooClose);
  });

  test('refuses a rate no frame-rate mismatch produces', () {
    // One mark landed on the wrong line: arithmetic would happily fit it.
    const first = SubtitleSyncAnchor(subtitleMs: 60000, actualMs: 60000);
    const second = SubtitleSyncAnchor(subtitleMs: 3600000, actualMs: 600000);

    final result = solveSubtitleSync(first, second);

    expect(result.solution, isNull);
    expect(result.rejection, SubtitleSyncRejection.implausibleRate);
  });

  test('refuses a shift the player would not hold', () {
    const first = SubtitleSyncAnchor(subtitleMs: 0, actualMs: 120000);
    const second = SubtitleSyncAnchor(subtitleMs: 1800000, actualMs: 1920000);

    final result = solveSubtitleSync(first, second);

    expect(result.solution, isNull);
    expect(result.rejection, SubtitleSyncRejection.implausibleDelay);
  });

  test('refuses a pair whose subtitle times do not advance', () {
    // Both marks on the same line, or a file whose timestamps went backwards.
    const first = SubtitleSyncAnchor(subtitleMs: 600000, actualMs: 60000);
    const second = SubtitleSyncAnchor(subtitleMs: 600000, actualMs: 1800000);

    expect(solveSubtitleSync(first, second).rejection, SubtitleSyncRejection.tooClose);
  });
}
