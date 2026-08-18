import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/video_equalizer.dart';

void main() {
  test('a fresh equalizer leaves the picture alone', () {
    expect(VideoEqualizer.neutral.isNeutral, isTrue);
    expect(VideoEqualizer.neutral.properties, {'brightness': '0', 'contrast': '0', 'saturation': '0', 'gamma': '0'});
  });

  test('one adjusted channel is enough to stop being neutral', () {
    expect(const VideoEqualizer(gamma: 5).isNeutral, isFalse);
  });

  test('values outside mpv range are clamped rather than rejected', () {
    final tooHigh = VideoEqualizer.neutral.copyWith(brightness: 400);
    final tooLow = VideoEqualizer.neutral.copyWith(contrast: -400);

    expect(tooHigh.brightness, VideoEqualizer.maxValue);
    expect(tooLow.contrast, VideoEqualizer.minValue);
  });

  test('a channel can be set and read back by name', () {
    var eq = VideoEqualizer.neutral;
    for (final channel in VideoEqualizerChannel.values) {
      eq = eq.withChannel(channel, 25);
    }

    for (final channel in VideoEqualizerChannel.values) {
      expect(eq.channel(channel), 25);
    }
  });

  test('setting one channel leaves the others alone', () {
    final eq = const VideoEqualizer(brightness: 10, contrast: 20).withChannel(VideoEqualizerChannel.saturation, 30);

    expect(eq.brightness, 10);
    expect(eq.contrast, 20);
    expect(eq.saturation, 30);
    expect(eq.gamma, 0);
  });

  test('equality is by value so a rewrite can be skipped', () {
    expect(const VideoEqualizer(brightness: 10), const VideoEqualizer(brightness: 10));
    expect(const VideoEqualizer(brightness: 10), isNot(const VideoEqualizer(brightness: 11)));
  });

  test('every preset is inside the range mpv accepts', () {
    for (final preset in VideoEqualizer.presets) {
      expect(preset, inInclusiveRange(VideoEqualizer.minValue, VideoEqualizer.maxValue));
      expect(VideoEqualizer.clamp(preset), preset);
    }
    expect(VideoEqualizer.presets, contains(0));
  });
}
