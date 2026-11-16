import 'package:flutter_test/flutter_test.dart';
import 'package:bask/media/transcode_explanation.dart';

void main() {
  group('parseMediaBrowserTranscodeReasons', () {
    test('maps the reasons a server actually sends', () {
      final reasons = parseMediaBrowserTranscodeReasons([
        'VideoCodecNotSupported',
        'AudioCodecNotSupported',
        'ContainerNotSupported',
        'VideoBitrateNotSupported',
        'VideoResolutionNotSupported',
        'SubtitleCodecNotSupported',
      ]);

      expect(reasons, [
        TranscodeReasonKind.videoCodec,
        TranscodeReasonKind.audioCodec,
        TranscodeReasonKind.container,
        TranscodeReasonKind.bitrate,
        TranscodeReasonKind.resolution,
        TranscodeReasonKind.subtitleBurnIn,
      ]);
    });

    test('folds related reasons into one kind without repeating it', () {
      // A profile and a level complaint are both "the video codec": saying it
      // three times is noise.
      final reasons = parseMediaBrowserTranscodeReasons([
        'VideoCodecNotSupported',
        'VideoProfileNotSupported',
        'VideoLevelNotSupported',
      ]);

      expect(reasons, [TranscodeReasonKind.videoCodec]);
    });

    test('keeps an unrecognized reason rather than dropping it', () {
      // "The server gave a reason we do not understand" still beats silence.
      expect(parseMediaBrowserTranscodeReasons(['SomethingNewInJellyfin']), [TranscodeReasonKind.unknown]);
    });
  });

  group('parsePlexDecisionText', () {
    test('reads the subject of the complaint out of the prose', () {
      expect(
        parsePlexDecisionText('Direct play not available because the audio codec is not supported'),
        contains(TranscodeReasonKind.audioCodec),
      );
      expect(
        parsePlexDecisionText('Transcoding because the container is not supported'),
        contains(TranscodeReasonKind.container),
      );
      expect(
        parsePlexDecisionText('Conversion required: bitrate exceeds the limit'),
        contains(TranscodeReasonKind.bitrate),
      );
    });

    test('says the server had a reason even when the sentence is unfamiliar', () {
      expect(parsePlexDecisionText('Something entirely new'), [TranscodeReasonKind.unknown]);
    });

    test('an empty decision explains nothing', () {
      expect(parsePlexDecisionText(null), isEmpty);
      expect(parsePlexDecisionText('   '), isEmpty);
    });
  });

  group('plexDecisionTextFrom', () {
    test('joins the fields that carry the prose, without repeating one', () {
      final text = plexDecisionTextFrom({
        'MediaContainer': {
          'generalDecisionText': 'Direct play not available',
          'mdeDecisionText': 'Direct play not available',
          'transcodeDecisionText': 'Transcoding to 1080p',
        },
      });

      expect(text, 'Direct play not available · Transcoding to 1080p');
    });

    test('a body with no prose explains nothing', () {
      expect(plexDecisionTextFrom({'MediaContainer': {}}), isNull);
      expect(plexDecisionTextFrom('not a map'), isNull);
    });
  });

  group('causedOnlyByOurCap', () {
    test('a bitrate-only transcode is the one the app can lift', () {
      // The cap is the app's own quality preset: one tap fixes it, and that
      // is the only case where offering "play the original" is honest.
      const explanation = TranscodeExplanation(reasons: [TranscodeReasonKind.bitrate]);
      expect(explanation.causedOnlyByOurCap, isTrue);
    });

    test('an unsupported codec would transcode at Original too', () {
      const explanation = TranscodeExplanation(reasons: [TranscodeReasonKind.bitrate, TranscodeReasonKind.audioCodec]);
      expect(explanation.causedOnlyByOurCap, isFalse);
    });

    test('no reasons means nothing to claim', () {
      expect(const TranscodeExplanation(reasons: []).causedOnlyByOurCap, isFalse);
    });
  });
}
