part of '../../video_player_screen.dart';

/// Picture adjustments (brightness/contrast/saturation/gamma), which this fork
/// adds on top of upstream's shader and zoom handling.
///
/// Kept in its own part rather than folded into [VisualEffectsController] so
/// the fork's surface stays separable from upstream's player internals.
extension _VideoPlayerEqualizerMethods on VideoPlayerScreenState {
  /// Applies picture adjustments and remembers them for the next video.
  void _setVideoEqualizer(VideoEqualizer equalizer) {
    final filterManager = _videoFilterManager;
    if (filterManager == null) return;

    unawaited(filterManager.setEqualizer(equalizer));
    unawaited(_persistVideoEqualizer(equalizer));
    if (mounted) _setPlayerState(() {});
  }

  Future<void> _persistVideoEqualizer(VideoEqualizer equalizer) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.videoBrightness, equalizer.brightness);
    await settings.write(SettingsService.videoContrast, equalizer.contrast);
    await settings.write(SettingsService.videoSaturation, equalizer.saturation);
    await settings.write(SettingsService.videoGamma, equalizer.gamma);
  }

  /// The stored picture adjustments, as written by [_setVideoEqualizer].
  VideoEqualizer _storedVideoEqualizer(SettingsService settings) => VideoEqualizer(
    brightness: settings.read(SettingsService.videoBrightness),
    contrast: settings.read(SettingsService.videoContrast),
    saturation: settings.read(SettingsService.videoSaturation),
    gamma: settings.read(SettingsService.videoGamma),
  );
}
