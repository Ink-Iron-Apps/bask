import 'package:flutter/foundation.dart';

/// Picture adjustments applied to the video itself.
///
/// mpv exposes brightness, contrast, saturation and gamma as integers from
/// -100 to 100, where 0 leaves the frame untouched. Values are held here rather
/// than read back from the player so the UI has something to show before a
/// video is loaded, and so a setting survives switching files.
@immutable
class VideoEqualizer {
  static const int minValue = -100;
  static const int maxValue = 100;

  /// Offered in the picker. Coarse on purpose: finer steps are indistinguishable
  /// on a phone screen and make the list unusable with a remote.
  static const List<int> presets = [-50, -25, -10, 0, 10, 25, 50];

  final int brightness;
  final int contrast;
  final int saturation;
  final int gamma;

  const VideoEqualizer({this.brightness = 0, this.contrast = 0, this.saturation = 0, this.gamma = 0});

  static const VideoEqualizer neutral = VideoEqualizer();

  /// Whether every channel is untouched, so the player can be left alone.
  bool get isNeutral => brightness == 0 && contrast == 0 && saturation == 0 && gamma == 0;

  static int clamp(int value) => value < minValue ? minValue : (value > maxValue ? maxValue : value);

  VideoEqualizer copyWith({int? brightness, int? contrast, int? saturation, int? gamma}) => VideoEqualizer(
    brightness: clamp(brightness ?? this.brightness),
    contrast: clamp(contrast ?? this.contrast),
    saturation: clamp(saturation ?? this.saturation),
    gamma: clamp(gamma ?? this.gamma),
  );

  VideoEqualizer withChannel(VideoEqualizerChannel channel, int value) => switch (channel) {
    VideoEqualizerChannel.brightness => copyWith(brightness: value),
    VideoEqualizerChannel.contrast => copyWith(contrast: value),
    VideoEqualizerChannel.saturation => copyWith(saturation: value),
    VideoEqualizerChannel.gamma => copyWith(gamma: value),
  };

  int channel(VideoEqualizerChannel channel) => switch (channel) {
    VideoEqualizerChannel.brightness => brightness,
    VideoEqualizerChannel.contrast => contrast,
    VideoEqualizerChannel.saturation => saturation,
    VideoEqualizerChannel.gamma => gamma,
  };

  /// The mpv properties this state maps to, ready to write.
  Map<String, String> get properties => {
    'brightness': '$brightness',
    'contrast': '$contrast',
    'saturation': '$saturation',
    'gamma': '$gamma',
  };

  @override
  bool operator ==(Object other) =>
      other is VideoEqualizer &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.gamma == gamma;

  @override
  int get hashCode => Object.hash(brightness, contrast, saturation, gamma);

  @override
  String toString() => 'VideoEqualizer(b:$brightness c:$contrast s:$saturation g:$gamma)';
}

enum VideoEqualizerChannel { brightness, contrast, saturation, gamma }
