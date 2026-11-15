import '../../../providers/playback_state_provider.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:provider/provider.dart';

import '../../../models/shader_preset.dart';
import '../../../media/playback_rate.dart';
import '../../../media/transcode_explanation.dart';
import '../../../models/transcode_quality_preset.dart';
import '../../../mpv/mpv.dart';
import '../../../mpv/player/player_native.dart';
import '../widgets/performance_overlay/performance_stats_service.dart';
import '../../../providers/shader_provider.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/scoped_player_prefs.dart';
import '../../../services/log_upload_service.dart';
import '../../../services/playback_problem_report.dart';
import '../../../services/settings_service.dart';
import '../../../services/subtitle_two_point_sync.dart';
import '../../../services/sleep_timer_service.dart';
import '../../../services/video_filter_manager.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../utils/dialogs.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/formatters.dart';
import '../../../utils/device_identity.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/quality_preset_labels.dart';
import '../../../utils/storage_space.dart';
import '../../../utils/latest_async_write.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../theme/mono_tokens.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/settings_builder.dart';
import '../../../widgets/overlay_sheet.dart';
import '../../../services/video_equalizer.dart';
import '../../../watch_together/providers/watch_together_provider.dart';
import '../models/track_controls_state.dart';
import '../widgets/sync_offset_control.dart';
import '../widgets/sleep_timer_content.dart';
import '../../../i18n/strings.g.dart';
import 'base_video_control_sheet.dart';
import 'version_quality_sheet.dart';

enum _SettingsView {
  menu,
  speed,
  zoom,
  versionQuality,
  sleep,
  audioDevice,
  shader,
  dvConversion,
  hdrToneMapping,
  subtitleRate,
  repeatQueue,
  picture,
  pictureChannel,
  dialogueBoostGain,
  downmixCenterBoost,
}

class _SettingsMenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String valueText;
  final VoidCallback onTap;
  final bool isHighlighted;
  final bool allowValueOverflow;

  const _SettingsMenuItem({
    required this.icon,
    required this.title,
    required this.valueText,
    required this.onTap,
    this.isHighlighted = false,
    this.allowValueOverflow = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens(context);
    final valueWidget = Text(
      valueText,
      style: TextStyle(color: isHighlighted ? Colors.amber : t.textMuted, fontSize: 14),
      overflow: allowValueOverflow ? TextOverflow.ellipsis : null,
    );

    return FocusableListTile(
      leading: AppIcon(icon, fill: 1, color: isHighlighted ? Colors.amber : t.textMuted),
      title: Text(title),
      trailing: Row(
        mainAxisSize: .min,
        children: [
          if (allowValueOverflow) Flexible(child: valueWidget) else valueWidget,
          const SizedBox(width: 8),
          AppIcon(Symbols.chevron_right_rounded, fill: 1, color: t.textMuted),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Ordering for the sheet's asynchronous pref writes, keyed on the pref key.
///
/// Shared by the toggle rows and the tone-mapping picker rather than owned by
/// either. A pick closes the sheet, so anything scoped to a widget cannot rank
/// a write against one started by a *later* sheet - which is exactly the race
/// here, since reopening and picking again is one tap. Keys are distinct per
/// pref and [LatestAsyncWrite] keeps a generation and tail per key, so the two
/// users never rank against each other.
final LatestAsyncWrite<String> _prefWrites = LatestAsyncWrite<String>();

/// Moves a setting on the device, records it, and puts both halves back when the
/// recording fails.
///
/// Device first is a decision, not an accident: a refusal is a validation. A
/// rejected `hdr-enabled` is how the plane reports that this session can never
/// carry HDR, so nothing may be recorded for a value the device would not take.
/// The price is a window in which the device leads the store, and closing that
/// window is what [_undoSettingWrite] is for - without it a rejected storage
/// write leaves the plane on the newly chosen policy while the switch and the
/// stored preference both still name the old one, for the rest of the session,
/// until the next player initialisation happens to replay the stored value.
///
/// Call this inside [LatestAsyncWrite.commitIfLatest] so a newer intent for the
/// same key cannot land between the failed write and the undo.
///
/// Rethrows whichever half failed, carrying its own stack: the caller owns what
/// the user sees, and for HDR that is a specific message about a surface no
/// retry can fix.
Future<void> _applyThenPersist<T>(Pref<T> pref, T value, FutureOr<void> Function(T value)? apply) async {
  if (apply == null) return SettingsService.instance.write(pref, value);
  // Read before the store is touched: SharedPreferencesWithCache moves its
  // in-process copy ahead of the platform write it may then fail, so asking
  // afterwards would answer with the value that did not persist.
  final restore = SettingsService.instance.read(pref);
  await apply(value);
  try {
    await SettingsService.instance.write(pref, value);
  } catch (error, stackTrace) {
    await _undoSettingWrite(pref, restore, apply);
    Error.throwWithStackTrace(error, stackTrace);
  }
}

/// Puts the store and the device back on [restore] after the store refused a
/// value the device had already taken.
///
/// Each half is attempted independently, the preference first: it is what the
/// next player initialisation replays into the device, so getting it right
/// salvages the session even when the device half then fails too. Failures are
/// logged and swallowed because the caller is already rethrowing the refusal
/// that started this, which is the one carrying a cause worth reporting.
Future<void> _undoSettingWrite<T>(Pref<T> pref, T restore, FutureOr<void> Function(T value) apply) async {
  try {
    // Rewriting the value already in the store looks redundant and is not: the
    // refused write moved SharedPreferencesWithCache's in-process copy before
    // the platform call it failed, and that copy is what SettingsService.read
    // answers with for the rest of the session. It is moved back here before
    // the platform call too, so it is repaired even if this write is refused
    // as well.
    await SettingsService.instance.write(pref, restore);
  } catch (error, stackTrace) {
    appLogger.w('Failed to restore the stored "${pref.key}"', error: error, stackTrace: stackTrace);
  }
  try {
    await apply(restore);
  } catch (error, stackTrace) {
    appLogger.w('Failed to restore "${pref.key}" on the device', error: error, stackTrace: stackTrace);
  }
}

class _SettingsToggleItem extends StatefulWidget {
  final Pref<bool> pref;
  final IconData icon;
  final String title;

  /// A line under the title, for saying why a switch that reads "on" is not
  /// doing anything.
  final String? subtitle;
  final FutureOr<void> Function(bool value)? onAfterWrite;

  const _SettingsToggleItem({
    required this.pref,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onAfterWrite,
  });

  @override
  State<_SettingsToggleItem> createState() => _SettingsToggleItemState();
}

class _SettingsToggleItemState extends State<_SettingsToggleItem> {
  bool? _pendingValue;
  int _writeGeneration = 0;

  @override
  void didUpdateWidget(covariant _SettingsToggleItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pref != widget.pref) {
      ++_writeGeneration;
      _pendingValue = null;
    }
  }

  @override
  void dispose() {
    ++_writeGeneration;
    super.dispose();
  }

  void _write(bool next) {
    final pref = widget.pref;
    final callback = widget.onAfterWrite;
    final generation = ++_writeGeneration;
    final writeToken = _prefWrites.begin(pref.key);
    setState(() {
      _pendingValue = next;
    });
    unawaited(_commitWrite(pref, callback, next, generation, writeToken));
  }

  Future<void> _commitWrite(
    Pref<bool> pref,
    FutureOr<void> Function(bool value)? callback,
    bool next,
    int generation,
    int writeToken,
  ) async {
    try {
      final committed = await _prefWrites.commitIfLatest(
        pref.key,
        writeToken,
        () => _applyThenPersist(pref, next, callback),
      );
      if (!committed || !mounted || generation != _writeGeneration) return;
      setState(() {
        _pendingValue = null;
      });
    } catch (error, stackTrace) {
      appLogger.w('Failed to update playback setting', error: error, stackTrace: stackTrace);
      if (!mounted || generation != _writeGeneration) return;
      setState(() {
        _pendingValue = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: settings.listenable(widget.pref),
      builder: (context, value, _) {
        final displayedValue = _pendingValue ?? value;
        final isPending = _pendingValue != null;
        final subtitle = widget.subtitle;
        return FocusableListTile(
          leading: AppIcon(widget.icon, fill: 1, color: displayedValue ? Colors.amber : tokens(context).textMuted),
          title: Text(widget.title),
          subtitle: subtitle == null
              ? null
              : Text(subtitle, style: TextStyle(color: tokens(context).textMuted, fontSize: 12)),
          trailing: Switch(value: displayedValue, onChanged: isPending ? null : _write, activeThumbColor: Colors.amber),
          onTap: isPending ? null : () => _write(!displayedValue),
        );
      },
    );
  }
}

/// Reflects the system's resolved audio rendering mode, as the Dolby
/// application guide requires. Renders nothing until the system reports a
/// conclusive value: Apple only resolves `renderingMode` for CarPlay and
/// AirPlay routes, and showing "Stereo" for an inconclusive HDMI route would
/// be worse than showing nothing.
class _AudioRenderingModeItem extends StatefulWidget {
  const _AudioRenderingModeItem({required this.player});

  final Player player;

  @override
  State<_AudioRenderingModeItem> createState() => _AudioRenderingModeItemState();
}

class _AudioRenderingModeItemState extends State<_AudioRenderingModeItem> {
  AudioRenderingMode? _mode;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final mode = await widget.player.getAudioRenderingMode();
    if (!mounted) return;
    setState(() => _mode = mode);
  }

  @override
  Widget build(BuildContext context) {
    final mode = _mode;
    if (mode == null || !mode.isConclusive) return const SizedBox.shrink();
    final label = switch (mode.rawValue) {
      AudioRenderingMode.dolbyAtmos => t.videoSettings.audioOutputDolbyAtmos,
      AudioRenderingMode.dolbyAudio => t.videoSettings.audioOutputDolbyAudio,
      AudioRenderingMode.surround => t.videoSettings.audioOutputSurround,
      AudioRenderingMode.spatialAudio => t.videoSettings.audioOutputSpatial,
      _ => t.videoSettings.audioOutputStereo,
    };
    final highlighted = mode.isDolbyAtmos || mode.isDolbyAudio;
    return FocusableListTile(
      leading: AppIcon(
        Symbols.spatial_audio_rounded,
        fill: 1,
        color: highlighted ? Colors.amber : tokens(context).textMuted,
      ),
      title: Text(t.videoSettings.audioOutput),
      trailing: Text(label, style: TextStyle(color: tokens(context).textMuted)),
    );
  }
}

/// Unified settings sheet for playback adjustments with in-sheet navigation
class VideoSettingsSheet extends StatefulWidget {
  final Player player;

  /// Whether this player surface supports Plezy's HDR control.
  ///
  /// Defaults to the native platform capability, but can be supplied by
  /// embedders whose capability is known independently of the host platform.
  final bool? supportsHdrControl;

  /// Shared player-control state. Every playback value and callback this sheet
  /// shows (sync offsets, zoom, versions/quality, shaders, ambient lighting,
  /// auto-hide) is read straight off it.
  final TrackControlsState trackControlsState;

  const VideoSettingsSheet({
    super.key,
    required this.player,
    this.supportsHdrControl,
    required this.trackControlsState,
  });

  @override
  State<VideoSettingsSheet> createState() => _VideoSettingsSheetState();
}

class _VideoSettingsSheetState extends State<VideoSettingsSheet> {
  _SettingsView _currentView = _SettingsView.menu;
  VideoEqualizerChannel _pictureChannel = VideoEqualizerChannel.brightness;
  late VideoEqualizer _equalizer = _state.videoEqualizer;
  late int _audioSyncOffset;
  late int _subtitleSyncOffset;
  late double _subtitleSpeed;
  late double _zoomScale;
  String _dvConversionMode = 'auto';
  int _dvConversionWriteGeneration = 0;
  // Linux only, and answered by the native side. Starts false so the toggle
  // never flashes into view on an output that cannot carry HDR.
  bool _linuxHdrSupported = false;
  // Re-probes that answer when the app is shown or resumed. Null wherever the
  // capability is a constant and there is nothing to re-probe.
  AppLifecycleListener? _hdrSupportLifecycle;
  // The lifecycle hooks miss the case that matters most here: dragging the
  // window to another monitor changes the answer without the app ever being
  // hidden. Only the plane sees that, so it says so.
  StreamSubscription<void>? _hdrOutputChanged;
  late HdrToneMapping _hdrToneMapping;

  TrackControlsState get _state => widget.trackControlsState;

  // An explicit value from the caller wins. Otherwise the capability is static
  // per platform, except on the Linux video plane where it depends on the
  // compositor, the output and the plane's bit depth, so it has to be asked for.
  bool get _supportsHdrControl =>
      widget.supportsHdrControl ??
      (_probesHdrSupport ? _linuxHdrSupported : Platform.isIOS || Platform.isMacOS || Platform.isWindows);

  // The Linux plane is the only path whose answer moves, and an explicit value
  // from the caller replaces the question altogether. Asked through
  // PlayerNative.usesLinuxVideoPlane, not Platform.isLinux, so the probe and the
  // tone-mapping row it gates resolve the same way under the test override.
  bool get _probesHdrSupport => PlayerNative.usesLinuxVideoPlane && widget.supportsHdrControl == null;

  bool get _showDebugDvConversionMode {
    if (!kDebugMode) return false;
    if (Platform.isAndroid) return widget.player.playerType == 'exoplayer';
    return (Platform.isIOS || Platform.isMacOS) && widget.player.playerType == 'mpv';
  }

  @override
  void initState() {
    super.initState();
    _audioSyncOffset = _state.audioSyncOffset;
    _subtitleSyncOffset = _state.subtitleSyncOffset;
    _subtitleSpeed = ScopedPlayerPrefs.resolve(ScopedPlayerPrefs.subtitleSpeed, _state.metadata);
    _zoomScale = VideoFilterManager.normalizeZoomScale(_state.videoZoomScale);
    _hdrToneMapping = SettingsService.instance.read(SettingsService.hdrToneMapping);
    _loadDebugDvConversionMode();
    if (_probesHdrSupport) {
      _hdrSupportLifecycle = AppLifecycleListener(onResume: _refreshLinuxHdrSupport, onShow: _refreshLinuxHdrSupport);
      _hdrOutputChanged = widget.player.streams.hdrOutputChanged.listen((_) => _refreshLinuxHdrSupport());
    }
    _refreshLinuxHdrSupport();
  }

  @override
  void dispose() {
    _hdrSupportLifecycle?.dispose();
    _hdrOutputChanged?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VideoSettingsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextZoomScale = VideoFilterManager.normalizeZoomScale(_state.videoZoomScale);
    if (_zoomScale != nextZoomScale) {
      _zoomScale = nextZoomScale;
    }
  }

  Future<void> _loadDebugDvConversionMode() async {
    if (!_showDebugDvConversionMode) return;
    final dvConversionMode = await widget.player.getProperty('dv-conversion-mode');
    if (!mounted) return;
    setState(() {
      _dvConversionMode = _normalizeDvConversionMode(dvConversionMode);
    });
  }

  // Asked again rather than cached for the sheet's lifetime. The native answer
  // is "this client can describe HDR *and* the output is in HDR right now", and
  // the second half moves when the window changes monitor or the display's HDR
  // mode is switched under us. The plane handles that internally and sends
  // nothing to Dart, so this rides the hooks that do exist: the app being shown
  // or resumed, and the menu coming back into view.
  Future<void> _refreshLinuxHdrSupport() async {
    if (!_probesHdrSupport) return;
    final player = widget.player;
    final supported = await player.isHdrOutputSupported();
    if (!mounted || player != widget.player || supported == _linuxHdrSupported) return;
    setState(() {
      _linuxHdrSupported = supported;
    });
  }

  // What the native side answers when the plane can never carry HDR - an 8-bit
  // EGL config, or a compositor without the colour-management protocol. Fixed
  // for the session, unlike a merely-SDR output, which is now accepted and
  // honoured once an HDR output is reached.
  static const String _hdrUnsupportedCode = 'HDR_UNSUPPORTED';

  // Rethrown so the switch still springs back. The message is what keeps that
  // from reading as a lost tap: retrying cannot help for the rest of the session.
  Future<void> _setHdrEnabled(bool enabled) async {
    try {
      await widget.player.setProperty('hdr-enabled', enabled ? 'yes' : 'no');
    } on PlatformException catch (error) {
      if (mounted && error.code == _hdrUnsupportedCode) showErrorSnackBar(context, t.videoSettings.hdrUnsupported);
      rethrow;
    }
  }

  void _setHdrToneMapping(HdrToneMapping mode) {
    final targetPlayer = widget.player;
    // The tiles stay tappable until close() runs, so two picks can be in flight.
    // The native side happens to queue HDR transactions in order, but that is not
    // an invariant this file can see: last write wins locally instead.
    //
    // Deliberately not gated on `mounted`: dismissing the sheet mid-write would
    // otherwise leave mpv in the new mode while the stored setting still named
    // the old one, and the next playback start would push the old one back.
    // A superseded pick can still persist transiently - the staleness check is
    // before the body, not inside it - but the winner is serialized behind it
    // and overwrites it, so the settled value is the last pick.
    final key = SettingsService.hdrToneMapping.key;
    final writeToken = _prefWrites.begin(key);
    unawaited(() async {
      try {
        final committed = await _prefWrites.commitIfLatest(
          key,
          writeToken,
          () => _applyThenPersist(
            SettingsService.hdrToneMapping,
            mode,
            (value) => targetPlayer.setProperty('hdr-tone-mapping', value.name),
          ),
        );
        if (!committed || !mounted || targetPlayer != widget.player) return;
        setState(() {
          _hdrToneMapping = mode;
        });
        OverlaySheetController.of(context).close();
      } catch (error, stackTrace) {
        appLogger.w('Failed to set the HDR tone-mapping mode', error: error, stackTrace: stackTrace);
        // The tick stays on the old mode by design (the stored setting was
        // left alone), but a dead tap needs saying so - the HDR toggle's
        // refusal shows a snackbar, and this is the same shape of refusal.
        if (mounted) showErrorSnackBar(context, t.videoSettings.hdrToneMappingFailed);
      }
    }());
  }

  void _setDebugDvConversionMode(String mode) {
    final targetPlayer = widget.player;
    final generation = ++_dvConversionWriteGeneration;
    unawaited(() async {
      try {
        await targetPlayer.setProperty('dv-conversion-mode', mode);
        if (!mounted || generation != _dvConversionWriteGeneration || targetPlayer != widget.player) return;
        setState(() {
          _dvConversionMode = mode;
        });
        OverlaySheetController.of(context).close();
      } catch (error, stackTrace) {
        appLogger.w('Failed to update Dolby Vision conversion mode', error: error, stackTrace: stackTrace);
      }
    }());
  }

  void _navigateTo(_SettingsView view) {
    setState(() {
      _currentView = view;
    });
    OverlaySheetController.maybeOf(context)?.refocus();
  }

  // Sync adjustments open as a compact top bar instead of a sub-view.
  void _openSyncBar({required bool isSubtitle}) {
    final controller = OverlaySheetController.maybeOf(context);
    if (controller == null) return;

    final title = isSubtitle ? t.videoSettings.subtitleSync : t.videoSettings.audioSync;
    final icon = isSubtitle ? Symbols.subtitles_rounded : Symbols.sync_rounded;
    final propertyName = isSubtitle ? 'sub-delay' : 'audio-delay';
    final initialOffset = isSubtitle ? _subtitleSyncOffset : _audioSyncOffset;

    // Created here so it can be passed as the overlay's initial focus target.
    // The creator disposes it after the overlay's lifecycle completes.
    final sliderFocusNode = FocusNode(debugLabel: 'SyncSlider');

    // show() with new alignment replaces the current sheet (completing the
    // settings sheet future, which restarts the auto-hide timer via
    // whenComplete in track_chapter_controls). Cancel it again here.
    controller
        .show(
          alignment: .topCenter,
          constraints: const BoxConstraints(maxHeight: 80, maxWidth: 900),
          initialFocusNode: sliderFocusNode,
          builder: (_) => _CompactSyncBar(
            title: title,
            icon: icon,
            player: widget.player,
            propertyName: propertyName,
            initialOffset: initialOffset,
            sliderFocusNode: sliderFocusNode,
            onOffsetChanged: (offset) async {
              final pref = isSubtitle ? ScopedPlayerPrefs.subtitleSyncOffset : ScopedPlayerPrefs.audioSyncOffset;
              await ScopedPlayerPrefs.write(pref, _state.metadata, offset);
            },
          ),
        )
        .whenComplete(() {
          sliderFocusNode.dispose();
          _state.onStartAutoHide?.call();
        });

    // Cancel auto-hide after show() — the previous sheet's whenComplete
    // fires as a microtask and restarts the timer, so schedule our cancel
    // to run after that microtask.
    Future.microtask(() => _state.onCancelAutoHide?.call());
  }

  void _navigateBack() {
    setState(() {
      _currentView = _SettingsView.menu;
    });
    // The HDR rows live on the menu only, so this is the moment a stale answer
    // becomes visible again.
    _refreshLinuxHdrSupport();
    OverlaySheetController.maybeOf(context)?.refocus();
  }

  String _getTitle() {
    switch (_currentView) {
      case _SettingsView.menu:
        return t.videoControls.settingsButton;
      case _SettingsView.speed:
        return t.videoSettings.playbackSpeed;
      case _SettingsView.zoom:
        return t.videoSettings.zoom;
      case _SettingsView.versionQuality:
        return _versionQualityTitle();
      case _SettingsView.sleep:
        return t.videoSettings.sleepTimer;
      case _SettingsView.audioDevice:
        return t.videoSettings.audioOutput;
      case _SettingsView.shader:
        return t.shaders.title;
      case _SettingsView.dvConversion:
        return t.settings.dvConversionMode;
      case _SettingsView.hdrToneMapping:
        return t.videoSettings.hdrToneMapping;
      case _SettingsView.subtitleRate:
        return t.videoSettings.subtitleRate;
      case _SettingsView.repeatQueue:
        return t.videoSettings.repeatQueue;
      case _SettingsView.picture:
        return t.videoSettings.pictureAdjustments;
      case _SettingsView.pictureChannel:
        return _pictureChannelLabel(_pictureChannel);
      case _SettingsView.dialogueBoostGain:
        return t.videoSettings.dialogueBoostGain;
      case _SettingsView.downmixCenterBoost:
        return t.videoSettings.downmixCenterBoost;
    }
  }

  IconData _getIcon() {
    switch (_currentView) {
      case _SettingsView.menu:
        return Symbols.tune_rounded;
      case _SettingsView.speed:
        return Symbols.speed_rounded;
      case _SettingsView.zoom:
        return Symbols.zoom_in_rounded;
      case _SettingsView.versionQuality:
        return Symbols.art_track_rounded;
      case _SettingsView.sleep:
        return Symbols.bedtime_rounded;
      case _SettingsView.audioDevice:
        return Symbols.speaker_rounded;
      case _SettingsView.shader:
        return Symbols.auto_fix_high_rounded;
      case _SettingsView.dvConversion:
        return Symbols.hdr_strong_rounded;
      case _SettingsView.hdrToneMapping:
        return Symbols.tonality_rounded;
      case _SettingsView.subtitleRate:
        return Symbols.speed_rounded;
      case _SettingsView.repeatQueue:
        return Symbols.repeat_rounded;
      case _SettingsView.picture:
      case _SettingsView.pictureChannel:
        return Symbols.exposure_rounded;
      case _SettingsView.dialogueBoostGain:
        return Symbols.tune_rounded;
      case _SettingsView.downmixCenterBoost:
        return Symbols.hearing_rounded;
    }
  }

  String _normalizeDvConversionMode(String? mode) {
    return switch (mode?.trim().toLowerCase()) {
      'disabled' || 'native' => 'disabled',
      'dv81' || 'p8' || 'p7_to_p8' || 'p7-to-p8' => 'dv81',
      'hevc' || 'hevc_strip' || 'p7_to_hevc' || 'p7-to-hevc' => 'hevc_strip',
      _ => 'auto',
    };
  }

  String _formatDvConversionMode(String mode) {
    return switch (_normalizeDvConversionMode(mode)) {
      'disabled' => t.settings.dvConversionNative,
      'dv81' => t.settings.dvConversionDv81,
      'hevc_strip' => t.settings.dvConversionHevcStrip,
      _ => t.settings.dvConversionAuto,
    };
  }

  String _formatHdrToneMapping(HdrToneMapping mode) => switch (mode) {
    HdrToneMapping.compositor => t.videoSettings.hdrToneMappingCompositor,
    HdrToneMapping.player => t.videoSettings.hdrToneMappingPlayer,
  };

  String _formatSleepTimer(SleepTimerService sleepTimer) {
    if (!sleepTimer.isActive) return t.common.off;
    // Armed by item count rather than by clock: there is no remaining time to
    // show, so name what it is still waiting for.
    final videos = sleepTimer.videosRemaining;
    if (videos > 0) {
      return videos == 1 ? t.videoControls.sleepTimerEndOfVideo : t.videoControls.sleepTimerEndOfVideos(count: videos);
    }
    final remaining = sleepTimer.remainingTime;
    if (remaining == null) return t.common.off;
    return t.videoSettings.sleepTimerActive(duration: formatDurationWithSeconds(remaining));
  }

  String _formatZoomScale(double scale) => '${(scale * 100).round()}%';

  void _setZoomScale(double scale) {
    final next = VideoFilterManager.normalizeZoomScale(scale);
    setState(() {
      _zoomScale = next;
    });
    _state.onVideoZoomChanged?.call(next);
  }

  void _resetZoomScale() {
    setState(() {
      _zoomScale = 1.0;
    });
    final reset = _state.onResetVideoZoom;
    if (reset != null) {
      reset();
    } else {
      _state.onVideoZoomChanged?.call(1.0);
    }
  }

  bool get _hasVersionQuality {
    return (_state.availableVersions.length > 1 || _state.serverSupportsTranscoding) &&
        (_state.onSwitchVersion != null || _state.onSwitchQualityPreset != null);
  }

  String _versionQualityTitle() {
    return versionQualityPickerTitle(
      showVersions: _state.availableVersions.length > 1,
      showQuality: _state.serverSupportsTranscoding,
    );
  }

  String _versionQualityValueText() {
    final values = <String>[];
    if (_state.availableVersions.length > 1) values.add(_selectedVersionLabel());
    if (_state.serverSupportsTranscoding) values.add(qualityPresetLabel(_state.selectedQualityPreset));
    return values.join(' / ');
  }

  String _selectedVersionLabel() {
    final index = _state.selectedMediaIndex;
    if (index >= 0 && index < _state.availableVersions.length) {
      return _state.availableVersions[index].displayLabel;
    }
    return t.videoControls.versionColumnHeader;
  }

  /// The reason line, or null when there is nothing to explain.
  String? _transcodeExplanationLine() {
    if (!_state.isTranscoding) return null;
    final explanation = _state.transcodeExplanation;
    if (explanation == null || explanation.isEmpty) return null;

    final reasons = explanation.reasons.map(_transcodeReasonLabel).toList();
    final serverText = explanation.serverText;
    return [
      if (reasons.isNotEmpty) reasons.join(', '),
      // Verbatim, below the classification: Plex answers in prose and a
      // sentence this build cannot parse is the one most worth reading.
      if (serverText != null && serverText.isNotEmpty) serverText,
    ].join('\n');
  }

  String _transcodeReasonLabel(TranscodeReasonKind kind) => switch (kind) {
    TranscodeReasonKind.videoCodec => t.videoSettings.transcodeReasonVideoCodec,
    TranscodeReasonKind.audioCodec => t.videoSettings.transcodeReasonAudioCodec,
    TranscodeReasonKind.container => t.videoSettings.transcodeReasonContainer,
    TranscodeReasonKind.bitrate => t.videoSettings.transcodeReasonBitrate,
    TranscodeReasonKind.resolution => t.videoSettings.transcodeReasonResolution,
    TranscodeReasonKind.subtitleBurnIn => t.videoSettings.transcodeReasonSubtitleBurnIn,
    TranscodeReasonKind.unknown => t.videoSettings.transcodeReasonUnknown,
  };

  /// Whether switching to the original would actually help.
  ///
  /// Only when the cap is ours to lift: a transcode forced by an unsupported
  /// codec happens at Original too, and offering it there would be advice
  /// that does not work.
  bool _canPlayOriginalInstead() {
    final explanation = _state.transcodeExplanation;
    return explanation != null &&
        explanation.causedOnlyByOurCap &&
        !_state.selectedQualityPreset.isOriginal &&
        _state.onSwitchQualityPreset != null;
  }

  /// Whether the backend has an `af` chain for the two audio filters to live
  /// in. ExoPlayer does not, so their rows stay hidden there rather than
  /// offering switches that do nothing.
  bool get _usesFilterChain => widget.player.playerType != 'exoplayer';

  /// Why the filter switches are doing nothing, or null when they are not.
  ///
  /// While passthrough is carrying a Dolby or DTS track, mpv hands it to the
  /// device as a bitstream, so there is no PCM for `af` to work on: both
  /// switches read "on" and neither is audible, which is exactly how a viewer
  /// concludes the boost is broken. ExoPlayer is the other way round —
  /// normalization force-decodes and wins over passthrough — so the note is
  /// gated on the same backend check as the rows themselves.
  String? get _filtersSuspendedNote =>
      _usesFilterChain && widget.player.audioPassthroughActive ? t.videoSettings.suspendedByPassthrough : null;

  /// How hard the dialogue boost pushes, under its own switch.
  Widget _dialogueBoostGainRow() => SettingsBuilder(
    prefs: const [SettingsService.dialogueBoost],
    builder: (context) {
      if (!SettingsService.instance.read(SettingsService.dialogueBoost)) return const SizedBox.shrink();
      return SettingValueBuilder<int>(
        pref: SettingsService.dialogueBoostGain,
        builder: (context, gainDb, _) => _SettingsMenuItem(
          icon: Symbols.tune_rounded,
          title: t.videoSettings.dialogueBoostGain,
          valueText: t.videoSettings.decibelBoost(db: gainDb.toString()),
          isHighlighted: true,
          onTap: () => _navigateTo(_SettingsView.dialogueBoostGain),
        ),
      );
    },
  );

  /// The two downmix settings that decide whether the downmix helps dialogue
  /// at all.
  ///
  /// They were reachable only from the app's own settings, which is the one
  /// place a viewer is not while a line goes by unheard — and a center boost
  /// of 0 dB is the swresample default, so the switch above could be turned on
  /// from here and change nothing but the channel count.
  Widget _downmixDetailRows() => SettingsBuilder(
    prefs: const [SettingsService.audioDownmix],
    builder: (context) {
      if (!SettingsService.instance.read(SettingsService.audioDownmix)) return const SizedBox.shrink();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingValueBuilder<int>(
            pref: SettingsService.downmixCenterBoost,
            builder: (context, centerBoostDb, _) => _SettingsMenuItem(
              icon: Symbols.hearing_rounded,
              title: t.videoSettings.downmixCenterBoost,
              valueText: centerBoostDb == 0 ? t.common.off : t.videoSettings.decibelBoost(db: centerBoostDb.toString()),
              isHighlighted: centerBoostDb > 0,
              onTap: () => _navigateTo(_SettingsView.downmixCenterBoost),
            ),
          ),
          _SettingsToggleItem(
            pref: SettingsService.audioDownmixNormalize,
            icon: Symbols.compress_rounded,
            title: t.videoSettings.audioDownmixNormalize,
            onAfterWrite: (normalize) => widget.player.setAudioDownmix(
              enabled: true,
              centerBoostDb: SettingsService.instance.read(SettingsService.downmixCenterBoost),
              normalize: normalize,
            ),
          ),
        ],
      );
    },
  );

  /// A dB picker for the two audio settings whose value is the whole point of
  /// the switch above them.
  ///
  /// Discrete steps rather than a slider: a remote lands on a row reliably and
  /// on a slider position only approximately, and steps finer than these are
  /// below what a living room will show.
  Widget _buildDbPickerView({
    required Pref<int> pref,
    required List<int> values,
    required FutureOr<void> Function(int value) apply,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return SettingValueBuilder<int>(
      pref: pref,
      builder: (context, current, _) => ListView(
        children: [
          for (final value in values)
            FocusableListTile(
              title: Text(
                value == 0 ? t.common.off : t.videoSettings.decibelBoost(db: value.toString()),
                style: TextStyle(color: value == current ? primary : null),
              ),
              trailing: value == current ? AppIcon(Symbols.check_rounded, fill: 1, color: primary) : null,
              onTap: () => _writeDbSetting(pref, value, apply),
            ),
        ],
      ),
    );
  }

  /// Ranked through the same [_prefWrites] queue as the toggle rows, so a
  /// second pick landing while the first is still being applied cannot leave
  /// the device on the value that was abandoned.
  void _writeDbSetting(Pref<int> pref, int value, FutureOr<void> Function(int value) apply) {
    final writeToken = _prefWrites.begin(pref.key);
    unawaited(
      _prefWrites.commitIfLatest(pref.key, writeToken, () => _applyThenPersist(pref, value, apply)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        appLogger.w('Failed to update "${pref.key}"', error: error, stackTrace: stackTrace);
        return false;
      }),
    );
  }

  Widget _buildMenuView() {
    final sleepTimer = SleepTimerService();
    final isDesktop = PlatformDetector.isDesktop(context);

    return ListView(
      shrinkWrap: true,
      children: [
        // Playback Speed - hidden for live TV and when user cannot control playback
        if (_state.canControl && !_state.isLive)
          StreamBuilder<double>(
            stream: widget.player.streams.rate,
            initialData: widget.player.state.rate,
            builder: (context, snapshot) {
              final currentRate = _displayedRate(snapshot.data ?? 1.0);
              return _SettingsMenuItem(
                icon: Symbols.speed_rounded,
                title: t.videoSettings.playbackSpeed,
                valueText: formatPlaybackRate(currentRate, normalAtOne: true),
                onTap: () => _navigateTo(_SettingsView.speed),
              );
            },
          ),

        if (_state.onVideoZoomChanged != null || _state.onResetVideoZoom != null)
          _SettingsMenuItem(
            icon: Symbols.zoom_in_rounded,
            title: t.videoSettings.zoom,
            valueText: _formatZoomScale(_zoomScale),
            isHighlighted: (_zoomScale - 1.0).abs() > 0.0001,
            onTap: () => _navigateTo(_SettingsView.zoom),
          ),

        if (_state.onVideoEqualizerChanged != null)
          _SettingsMenuItem(
            icon: Symbols.exposure_rounded,
            title: t.videoSettings.pictureAdjustments,
            valueText: _equalizer.isNeutral ? t.videoSettings.pictureNeutral : _pictureSummary(),
            isHighlighted: !_equalizer.isNeutral,
            onTap: () => _navigateTo(_SettingsView.picture),
          ),

        if (_hasVersionQuality)
          _SettingsMenuItem(
            icon: Symbols.art_track_rounded,
            title: _versionQualityTitle(),
            valueText: _versionQualityValueText(),
            allowValueOverflow: true,
            onTap: () => _navigateTo(_SettingsView.versionQuality),
          ),

        // Sleep Timer
        ListenableBuilder(
          listenable: sleepTimer,
          builder: (context, _) {
            final isActive = sleepTimer.isActive;
            return _SettingsMenuItem(
              icon: Symbols.bedtime_rounded,
              title: t.videoSettings.sleepTimer,
              valueText: _formatSleepTimer(sleepTimer),
              isHighlighted: isActive,
              onTap: () => _navigateTo(_SettingsView.sleep),
            );
          },
        ),

        _SettingsMenuItem(
          icon: Symbols.sync_rounded,
          title: t.videoSettings.audioSync,
          valueText: formatSyncOffset(_audioSyncOffset.toDouble()),
          isHighlighted: _audioSyncOffset != 0,
          onTap: () => _openSyncBar(isSubtitle: false),
        ),

        // Only with a queue behind the current item: repeat describes what
        // happens at the end of one, and there is nothing to say without it.
        if (_playbackState?.isQueueActive ?? false)
          _SettingsMenuItem(
            icon: Symbols.repeat_rounded,
            title: t.videoSettings.repeatQueue,
            valueText: _playbackState?.repeatMode == VideoRepeatMode.all
                ? t.videoSettings.repeatQueueAll
                : t.videoSettings.repeatQueueOff,
            isHighlighted: (_playbackState?.repeatMode ?? VideoRepeatMode.off) != VideoRepeatMode.off,
            onTap: () => _navigateTo(_SettingsView.repeatQueue),
          ),

        _SettingsMenuItem(
          icon: Symbols.subtitles_rounded,
          title: t.videoSettings.subtitleSync,
          valueText: formatSyncOffset(_subtitleSyncOffset.toDouble()),
          isHighlighted: _subtitleSyncOffset != 0,
          onTap: () => _openSyncBar(isSubtitle: true),
        ),

        // Separate from the offset because it fixes a different fault: an
        // offset shifts every line by the same amount, which cannot correct a
        // file authored against another frame rate.
        _SettingsMenuItem(
          icon: Symbols.av_timer_rounded,
          title: t.videoSettings.subtitleRate,
          valueText: _formatSubtitleRate(_subtitleSpeed),
          isHighlighted: _subtitleSpeed != 1.0,
          onTap: () => _navigateTo(_SettingsView.subtitleRate),
        ),

        // Two points fix a shift and a rate together, which is what a
        // subtitle from a different release usually needs.
        _SettingsMenuItem(
          icon: Symbols.ads_click_rounded,
          title: t.videoSettings.subtitleMarkSync,
          valueText: _pendingSyncAnchor == null
              ? t.videoSettings.subtitleMarkSyncFirst
              : t.videoSettings.subtitleMarkSyncSecond,
          isHighlighted: _pendingSyncAnchor != null,
          allowValueOverflow: true,
          onTap: () => unawaited(_markSubtitleSyncLine()),
        ),

        if (_supportsHdrControl)
          _SettingsToggleItem(
            pref: SettingsService.enableHDR,
            icon: Symbols.hdr_strong_rounded,
            title: t.videoSettings.hdr,
            onAfterWrite: _setHdrEnabled,
          ),

        // Only meaningful where the plane can actually carry HDR, and only the
        // Linux plane lets us pick the curve: elsewhere the platform decides who
        // tone-maps.
        if (_supportsHdrControl && PlayerNative.usesLinuxVideoPlane)
          _SettingsMenuItem(
            icon: Symbols.tonality_rounded,
            title: t.videoSettings.hdrToneMapping,
            valueText: _formatHdrToneMapping(_hdrToneMapping),
            onTap: () => _navigateTo(_SettingsView.hdrToneMapping),
          ),

        _SettingsToggleItem(
          pref: SettingsService.autoPlayNextEpisode,
          icon: Symbols.skip_next_rounded,
          title: t.videoControls.autoPlayNext,
        ),

        if (isDesktop)
          StreamBuilder<AudioDevice>(
            stream: widget.player.streams.audioDevice,
            initialData: widget.player.state.audioDevice,
            builder: (context, snapshot) {
              final currentDevice = snapshot.data ?? widget.player.state.audioDevice;
              final deviceLabel = currentDevice.description.isEmpty ? currentDevice.name : currentDevice.description;

              return _SettingsMenuItem(
                icon: Symbols.speaker_rounded,
                title: t.videoSettings.audioOutput,
                valueText: deviceLabel,
                allowValueOverflow: true,
                onTap: () => _navigateTo(_SettingsView.audioDevice),
              );
            },
          ),

        // Audio Passthrough is not here: it configures the audio output route rather
        // than this playback, and applying it mid-stream bounces the audio renderer and
        // re-decides video tunneling. It lives in Settings > Video Playback next to
        // Tunneled Playback, which is applied the same way — at the next player start.

        // Dolby playback badge. The Dolby application guide requires the app
        // to reflect AVAudioSession.renderingMode; Apple only resolves that
        // for CarPlay/AirPlay routes, so it is hidden rather than shown as
        // "not Dolby" when the system reports notApplicable.
        if (PlatformDetector.isAppleTV()) _AudioRenderingModeItem(player: widget.player),

        _SettingsToggleItem(
          pref: SettingsService.audioNormalization,
          icon: Symbols.graphic_eq_rounded,
          title: t.videoSettings.audioNormalization,
          subtitle: _filtersSuspendedNote,
          onAfterWrite: widget.player.setAudioNormalization,
        ),

        // Where the problem is actually noticed: a line goes by unheard and
        // the viewer reaches for the remote. Hidden on ExoPlayer, which has no
        // filter chain to extend — gated on the configured backend, so a
        // session that silently fell back to mpv does not grow a row mid-film.
        if (_usesFilterChain)
          _SettingsToggleItem(
            pref: SettingsService.dialogueBoost,
            icon: Symbols.record_voice_over_rounded,
            title: t.videoSettings.dialogueBoost,
            subtitle: _filtersSuspendedNote,
            onAfterWrite: (enabled) => widget.player.setDialogueBoost(
              enabled: enabled,
              gainDb: SettingsService.instance.read(SettingsService.dialogueBoostGain),
            ),
          ),
        if (_usesFilterChain) _dialogueBoostGainRow(),

        _SettingsToggleItem(
          pref: SettingsService.audioDownmix,
          icon: Symbols.headphones_rounded,
          title: t.videoSettings.audioDownmix,
          onAfterWrite: (enabled) => widget.player.setAudioDownmix(
            enabled: enabled,
            centerBoostDb: SettingsService.instance.read(SettingsService.downmixCenterBoost),
            normalize: SettingsService.instance.read(SettingsService.audioDownmixNormalize),
          ),
        ),
        _downmixDetailRows(),

        // Shader Preset (MPV only)
        if (_state.shaderService != null && _state.shaderService!.isSupported)
          _SettingsMenuItem(
            icon: Symbols.auto_fix_high_rounded,
            title: t.shaders.title,
            valueText: _shaderPresetTitle(_state.shaderService!.currentPreset),
            isHighlighted: _state.shaderService!.currentPreset.isEnabled,
            onTap: () => _navigateTo(_SettingsView.shader),
          ),

        // Ambient Lighting (MPV only)
        if (_state.onToggleAmbientLighting != null)
          FocusableListTile(
            leading: AppIcon(
              Symbols.blur_on_rounded,
              fill: 1,
              color: _state.isAmbientLightingEnabled ? Colors.amber : tokens(context).textMuted,
            ),
            title: Text(t.videoControls.ambientLighting),
            trailing: Switch(
              value: _state.isAmbientLightingEnabled,
              onChanged: (_) {
                _state.onToggleAmbientLighting?.call();
                OverlaySheetController.of(context).close();
              },
              activeThumbColor: Colors.amber,
            ),
            onTap: () {
              _state.onToggleAmbientLighting?.call();
              OverlaySheetController.of(context).close();
            },
          ),

        // Why the server is re-encoding, and the one remedy that lives in the
        // app: the quality cap. The server's own words are shown underneath
        // whatever this build could classify, because a reason it does not
        // recognize is still worth reading.
        if (_transcodeExplanationLine() case final String line)
          FocusableListTile(
            leading: AppIcon(Symbols.info_rounded, fill: 1, color: tokens(context).textMuted),
            title: Text(t.videoSettings.transcodeWhy),
            subtitle: Text(line, style: TextStyle(color: tokens(context).textMuted, fontSize: 12)),
            onTap: _canPlayOriginalInstead()
                ? () {
                    OverlaySheetController.of(context).close();
                    _state.onSwitchQualityPreset?.call(TranscodeQualityPreset.original);
                  }
                : null,
            trailing: _canPlayOriginalInstead()
                ? Text(
                    t.videoSettings.transcodePlayOriginal,
                    style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12),
                  )
                : null,
          ),

        // Performance Overlay Toggle
        _SettingsToggleItem(
          pref: SettingsService.showPerformanceOverlay,
          icon: Symbols.analytics_rounded,
          title: t.videoSettings.performanceOverlay,
        ),

        // What the overlay shows, captured rather than watched: whatever is
        // wrong is happening now, and none of it survives to be asked about
        // later.
        FocusableListTile(
          leading: AppIcon(Symbols.bug_report_rounded, fill: 1, color: tokens(context).textMuted),
          title: Text(t.videoSettings.reportPlaybackProblem),
          onTap: () {
            OverlaySheetController.of(context).close();
            unawaited(_reportPlaybackProblem());
          },
        ),

        if (_showDebugDvConversionMode)
          _SettingsMenuItem(
            icon: Symbols.hdr_strong_rounded,
            title: t.settings.dvConversionMode,
            valueText: _formatDvConversionMode(_dvConversionMode),
            isHighlighted: _dvConversionMode != 'auto',
            onTap: () => _navigateTo(_SettingsView.dvConversion),
          ),

        // Debug: Trigger MPV Fallback (Android ExoPlayer only)
        if (kDebugMode && Platform.isAndroid && widget.player.playerType == 'exoplayer')
          FocusableListTile(
            leading: AppIcon(Symbols.swap_horiz_rounded, fill: 1, color: tokens(context).textMuted),
            title: const Text('Trigger MPV Fallback'),
            onTap: () {
              const MethodChannel('com.plezy/exo_player').invokeMethod('triggerFallback');
              OverlaySheetController.of(context).close();
            },
          ),

        if (kDebugMode)
          for (final status in const [500, 404, 503])
            FocusableListTile(
              leading: AppIcon(Symbols.bug_report_rounded, fill: 1, color: tokens(context).textMuted),
              title: Text('Simulate HTTP $status from server'),
              onTap: () {
                final player = widget.player;
                OverlaySheetController.of(context).close();
                if (player is PlayerBase) {
                  player.debugSimulateServerHttpError(status);
                }
              },
            ),
      ],
    );
  }

  /// Capture what the player is doing, with the log around it, and upload it.
  ///
  /// Asks first: this leaves the device, and a log carries titles and server
  /// names even after redaction takes the credentials out. The id comes back
  /// for the user to quote, which is the whole point — a stutter or a silent
  /// dropout says nothing about itself an hour later.
  Future<void> _reportPlaybackProblem() async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.videoSettings.reportPlaybackProblem,
      message: t.videoSettings.reportPlaybackProblemDescription,
      confirmText: t.videoSettings.reportPlaybackProblemSend,
    );
    if (!confirmed || !mounted) return;

    showLoadingDialog(context);
    try {
      final stats = await PerformanceStatsService(widget.player).captureOnce();
      final identity = await DeviceIdentityService.resolve();
      final packageInfo = await PackageInfo.fromPlatform();
      final report = buildPlaybackProblemReport(
        now: DateTime.now(),
        appVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
        platform: identity.platform,
        deviceModel: identity.deviceModel,
        stats: stats,
        item: _state.metadata,
        storage: await StorageSpace.measure(await getApplicationSupportDirectory()),
        logs: MemoryLogOutput.getLogs(),
      );

      final id = await uploadDiagnosticText(report);
      if (!mounted) return;
      Navigator.of(context).pop();
      await showDiagnosticIdDialog(context, id);
    } catch (e, stackTrace) {
      appLogger.e('Could not report the playback problem', error: e, stackTrace: stackTrace);
      if (!mounted) return;
      Navigator.of(context).pop();
      showErrorSnackBar(context, t.videoSettings.reportPlaybackProblemFailed);
    }
  }

  Widget _buildDvConversionView() {
    final modes = [
      (value: 'auto', title: t.settings.dvConversionAuto, subtitle: t.settings.dvConversionAutoDescription),
      (value: 'disabled', title: t.settings.dvConversionNative, subtitle: t.settings.dvConversionNativeDescription),
      (value: 'dv81', title: t.settings.dvConversionDv81, subtitle: t.settings.dvConversionDv81Description),
      (
        value: 'hevc_strip',
        title: t.settings.dvConversionHevcStrip,
        subtitle: t.settings.dvConversionHevcStripDescription,
      ),
    ];
    final primary = Theme.of(context).colorScheme.primary;

    return ListView(
      shrinkWrap: true,
      children: [
        for (final mode in modes)
          FocusableListTile(
            title: Text(mode.title, style: TextStyle(color: _dvConversionMode == mode.value ? primary : null)),
            subtitle: Text(mode.subtitle, style: TextStyle(color: tokens(context).textMuted, fontSize: 12)),
            trailing: _dvConversionMode == mode.value ? AppIcon(Symbols.check_rounded, fill: 1, color: primary) : null,
            onTap: () => _setDebugDvConversionMode(mode.value),
          ),
      ],
    );
  }

  Widget _buildHdrToneMappingView() {
    final modes = [
      (value: HdrToneMapping.compositor, subtitle: t.videoSettings.hdrToneMappingCompositorDescription),
      (value: HdrToneMapping.player, subtitle: t.videoSettings.hdrToneMappingPlayerDescription),
    ];
    final primary = Theme.of(context).colorScheme.primary;

    return ListView(
      children: [
        for (final mode in modes)
          FocusableListTile(
            title: Text(
              _formatHdrToneMapping(mode.value),
              style: TextStyle(color: _hdrToneMapping == mode.value ? primary : null),
            ),
            subtitle: Text(mode.subtitle, style: TextStyle(color: tokens(context).textMuted, fontSize: 12)),
            trailing: _hdrToneMapping == mode.value ? AppIcon(Symbols.check_rounded, fill: 1, color: primary) : null,
            onTap: () => _setHdrToneMapping(mode.value),
          ),
      ],
    );
  }

  /// The two frame-rate conversions that actually occur in the wild, plus off.
  ///
  /// A free slider would be worse here: the error is never arbitrary, it is
  /// one of these two ratios, and reading "95.9%" off a slider is harder than
  /// recognising which release the subtitles came from.
  static const double _subtitleRateSlower = 24000 / 1001 / 25; // 25 fps subs on 23.976 video
  static const double _subtitleRateFaster = 25 / (24000 / 1001);

  String _formatSubtitleRate(double speed) {
    if ((speed - _subtitleRateSlower).abs() < 0.0005) return t.videoSettings.subtitleRateSlower;
    if ((speed - _subtitleRateFaster).abs() < 0.0005) return t.videoSettings.subtitleRateFaster;
    if (speed == 1.0) return t.videoSettings.subtitleRateNormal;
    return '${(speed * 100).toStringAsFixed(1)}%';
  }

  /// The first marked line, while waiting for its pair.
  SubtitleSyncAnchor? _pendingSyncAnchor;

  /// Mark the line showing now, and solve once there are two.
  ///
  /// Two points fix a shift and a rate at once, which is the case neither
  /// existing control can handle alone: a subtitle for a release with a
  /// different intro length is both shifted and, if it came from another
  /// transfer, running at the wrong rate. The viewer marks a line near the
  /// start and one near the end and the line through them is the answer —
  /// no guessing about the cause, and no reliance on a frame-rate ratio the
  /// file may not have.
  Future<void> _markSubtitleSyncLine() async {
    final player = widget.player;
    final subStartSeconds = double.tryParse(await player.getProperty('sub-start') ?? '');
    final positionMs = player.state.position.inMilliseconds;

    if (subStartSeconds == null) {
      // Nothing on screen to mark. Marking the gap between lines would anchor
      // to whatever happened to be nearest, which is how a sync tool earns
      // its reputation.
      if (mounted) showAppSnackBar(context, t.videoSettings.subtitleMarkSyncNoLine);
      return;
    }

    // Where the line's own timestamp puts it, before any correction in force,
    // so a second pass over an already-adjusted file still solves correctly.
    final authoredMs = ((subStartSeconds - _subtitleSyncOffset / 1000.0) * _subtitleSpeed * 1000).round();
    final anchor = SubtitleSyncAnchor(subtitleMs: authoredMs, actualMs: positionMs);

    final pending = _pendingSyncAnchor;
    if (pending == null) {
      setState(() => _pendingSyncAnchor = anchor);
      if (mounted) showAppSnackBar(context, t.videoSettings.subtitleMarkSyncSecond);
      return;
    }

    final result = solveSubtitleSync(pending, anchor);
    final solution = result.solution;
    if (solution == null) {
      setState(() => _pendingSyncAnchor = null);
      if (!mounted) return;
      showErrorSnackBar(
        context,
        result.rejection == SubtitleSyncRejection.tooClose
            ? t.videoSettings.subtitleMarkSyncTooClose
            : t.videoSettings.subtitleMarkSyncImplausible,
      );
      return;
    }

    setState(() => _pendingSyncAnchor = null);
    await _setSubtitleRate(solution.speed);
    await _setSubtitleOffsetMs(solution.delayMs);
    if (mounted) showAppSnackBar(context, t.videoSettings.subtitleMarkSyncApplied);
  }

  /// Apply and persist a subtitle delay, the way the sync bar does.
  Future<void> _setSubtitleOffsetMs(int offsetMs) async {
    setState(() => _subtitleSyncOffset = offsetMs);
    await ScopedPlayerPrefs.write(ScopedPlayerPrefs.subtitleSyncOffset, _state.metadata, offsetMs);
    try {
      await widget.player.setProperty('sub-delay', (offsetMs / 1000.0).toString());
    } catch (e) {
      appLogger.w('Could not apply the subtitle offset', error: e);
    }
  }

  Future<void> _setSubtitleRate(double speed) async {
    setState(() => _subtitleSpeed = speed);
    await ScopedPlayerPrefs.write(ScopedPlayerPrefs.subtitleSpeed, _state.metadata, speed);
    try {
      await widget.player.setProperty('sub-speed', speed.toStringAsFixed(5));
    } catch (e) {
      appLogger.w('Could not apply the subtitle rate', error: e);
    }
    if (mounted) _navigateTo(_SettingsView.menu);
  }

  /// The queue, when this sheet is inside a player that has one.
  ///
  /// The sheet is also built without the player's providers above it — the
  /// widget tests do exactly that — so absence is a normal state, not a bug
  /// to throw on. Mirrors how the speed view reaches for Watch Together.
  PlaybackStateProvider? get _playbackState {
    try {
      return context.watch<PlaybackStateProvider>();
    } catch (_) {
      return null;
    }
  }

  Widget _buildRepeatQueueView() {
    final playbackState = _playbackState;
    if (playbackState == null) return const SizedBox.shrink();
    final primary = Theme.of(context).colorScheme.primary;
    final modes = [
      (
        value: VideoRepeatMode.off,
        label: t.videoSettings.repeatQueueOff,
        subtitle: t.videoSettings.repeatQueueOffDescription,
      ),
      (
        value: VideoRepeatMode.all,
        label: t.videoSettings.repeatQueueAll,
        subtitle: t.videoSettings.repeatQueueAllDescription,
      ),
    ];

    return ListView(
      children: [
        for (final mode in modes)
          FocusableListTile(
            title: Text(mode.label, style: TextStyle(color: playbackState.repeatMode == mode.value ? primary : null)),
            subtitle: Text(mode.subtitle, style: TextStyle(color: tokens(context).textMuted, fontSize: 12)),
            trailing: playbackState.repeatMode == mode.value
                ? AppIcon(Symbols.check_rounded, fill: 1, color: primary)
                : null,
            onTap: () {
              playbackState.setRepeatMode(mode.value);
              _navigateTo(_SettingsView.menu);
            },
          ),
      ],
    );
  }

  Widget _buildSubtitleRateView() {
    final rates = [
      (value: 1.0, label: t.videoSettings.subtitleRateNormal, subtitle: t.videoSettings.subtitleRateNormalDescription),
      (
        value: _subtitleRateSlower,
        label: t.videoSettings.subtitleRateSlower,
        subtitle: t.videoSettings.subtitleRateSlowerDescription,
      ),
      (
        value: _subtitleRateFaster,
        label: t.videoSettings.subtitleRateFaster,
        subtitle: t.videoSettings.subtitleRateFasterDescription,
      ),
    ];
    final primary = Theme.of(context).colorScheme.primary;

    return ListView(
      children: [
        for (final rate in rates)
          FocusableListTile(
            title: Text(
              rate.label,
              style: TextStyle(color: (_subtitleSpeed - rate.value).abs() < 0.0005 ? primary : null),
            ),
            subtitle: Text(rate.subtitle, style: TextStyle(color: tokens(context).textMuted, fontSize: 12)),
            trailing: (_subtitleSpeed - rate.value).abs() < 0.0005
                ? AppIcon(Symbols.check_rounded, fill: 1, color: primary)
                : null,
            onTap: () => unawaited(_setSubtitleRate(rate.value)),
          ),
      ],
    );
  }

  /// The rate the user chose, as opposed to what the player is momentarily
  /// running at: a Watch Together drift nudge is not a speed setting.
  double _displayedRate(double playerRate) {
    try {
      final session = context.read<WatchTogetherProvider>();
      if (session.syncOwnsRate) return session.roomRate ?? playerRate;
    } catch (_) {
      // No session provider above this sheet.
    }
    return playerRate;
  }

  Widget _buildSpeedView() {
    return StreamBuilder<double>(
      stream: widget.player.streams.rate,
      initialData: widget.player.state.rate,
      builder: (context, snapshot) {
        final currentRate = _displayedRate(snapshot.data ?? 1.0);
        const speeds = <double>[
          0.5,
          0.75,
          1.0,
          1.25,
          1.5,
          1.75,
          2.0,
          2.25,
          2.5,
          2.75,
          3.0,
          3.5,
          4.0,
          4.5,
          5.0,
          6.0,
          7.0,
          maximumPlaybackRate,
        ];

        return ListView.builder(
          shrinkWrap: true,
          itemCount: speeds.length,
          itemBuilder: (context, index) {
            final speed = speeds[index];
            final isSelected = (currentRate - speed).abs() < 0.01;
            final label = formatPlaybackRate(speed, normalAtOne: true);

            final primary = Theme.of(context).colorScheme.primary;
            return FocusableListTile(
              title: Text(label, style: TextStyle(color: isSelected ? primary : null)),
              trailing: isSelected ? AppIcon(Symbols.check_rounded, fill: 1, color: primary) : null,
              onTap: () async {
                await (_state.onRateRequested ?? widget.player.setRate)(speed);
                // Save at the configured persistence scope (global by default).
                await ScopedPlayerPrefs.write(ScopedPlayerPrefs.playbackSpeed, _state.metadata, speed);
                if (context.mounted) {
                  OverlaySheetController.of(context).close(); // Close sheet after selection
                }
              },
            );
          },
        );
      },
    );
  }

  Widget _buildZoomView() {
    const zoomPresets = [0.5, 0.75, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.75, 2.0];
    final primary = Theme.of(context).colorScheme.primary;

    return ListView(
      shrinkWrap: true,
      children: [
        FocusableListTile(
          leading: AppIcon(Symbols.restart_alt_rounded, fill: 1, color: tokens(context).textMuted),
          title: Text(t.common.reset),
          onTap: _resetZoomScale,
        ),
        for (final scale in zoomPresets)
          FocusableListTile(
            title: Text(
              _formatZoomScale(scale),
              style: TextStyle(color: (_zoomScale - scale).abs() < 0.005 ? primary : null),
            ),
            trailing: (_zoomScale - scale).abs() < 0.005
                ? AppIcon(Symbols.check_rounded, fill: 1, color: primary)
                : null,
            onTap: () => _setZoomScale(scale),
          ),
      ],
    );
  }

  String _pictureChannelLabel(VideoEqualizerChannel channel) => switch (channel) {
    VideoEqualizerChannel.brightness => t.videoSettings.pictureBrightness,
    VideoEqualizerChannel.contrast => t.videoSettings.pictureContrast,
    VideoEqualizerChannel.saturation => t.videoSettings.pictureSaturation,
    VideoEqualizerChannel.gamma => t.videoSettings.pictureGamma,
  };

  String _formatPictureValue(int value) => value > 0 ? '+$value' : '$value';

  /// Only the channels that have been moved, so the menu row stays short.
  String _pictureSummary() => VideoEqualizerChannel.values
      .where((channel) => _equalizer.channel(channel) != 0)
      .map((channel) => '${_pictureChannelLabel(channel)[0]}${_formatPictureValue(_equalizer.channel(channel))}')
      .join(' ');

  void _setEqualizer(VideoEqualizer next) {
    setState(() => _equalizer = next);
    _state.onVideoEqualizerChanged?.call(next);
  }

  Widget _buildPictureView() {
    final primary = Theme.of(context).colorScheme.primary;

    return ListView(
      shrinkWrap: true,
      children: [
        FocusableListTile(
          leading: AppIcon(Symbols.restart_alt_rounded, fill: 1, color: tokens(context).textMuted),
          title: Text(t.common.reset),
          onTap: () => _setEqualizer(VideoEqualizer.neutral),
        ),
        for (final channel in VideoEqualizerChannel.values)
          FocusableListTile(
            title: Text(_pictureChannelLabel(channel)),
            trailing: Text(
              _equalizer.channel(channel) == 0
                  ? t.videoSettings.pictureNeutral
                  : _formatPictureValue(_equalizer.channel(channel)),
              style: TextStyle(color: _equalizer.channel(channel) == 0 ? null : primary),
            ),
            onTap: () {
              setState(() => _pictureChannel = channel);
              _navigateTo(_SettingsView.pictureChannel);
            },
          ),
      ],
    );
  }

  Widget _buildPictureChannelView() {
    final primary = Theme.of(context).colorScheme.primary;
    final current = _equalizer.channel(_pictureChannel);

    return ListView(
      shrinkWrap: true,
      children: [
        for (final preset in VideoEqualizer.presets)
          FocusableListTile(
            title: Text(
              preset == 0 ? t.videoSettings.pictureNeutral : _formatPictureValue(preset),
              style: TextStyle(color: preset == current ? primary : null),
            ),
            trailing: preset == current ? AppIcon(Symbols.check_rounded, fill: 1, color: primary) : null,
            onTap: () => _setEqualizer(_equalizer.withChannel(_pictureChannel, preset)),
          ),
      ],
    );
  }

  Widget _buildSleepView() {
    final sleepTimer = SleepTimerService();

    return SleepTimerContent(sleepTimer: sleepTimer, onCancel: () => OverlaySheetController.of(context).close());
  }

  Widget _buildVersionQualityView() {
    return VersionQualityPicker(
      availableVersions: _state.availableVersions,
      selectedMediaIndex: _state.selectedMediaIndex,
      selectedQualityPreset: _state.selectedQualityPreset,
      serverSupportsTranscoding: _state.serverSupportsTranscoding,
      sourceDurationMs: _state.sourceDurationMs,
      onVersionSelected: (index) => _state.onSwitchVersion?.call(index),
      onQualitySelected: (preset) => _state.onSwitchQualityPreset?.call(preset),
    );
  }

  /// Extract the audio backend name from a device name (e.g. "coreaudio" from "coreaudio/BuiltIn").
  static String _audioBackend(String name) {
    final slash = name.indexOf('/');
    return slash > 0 ? name.substring(0, slash) : name;
  }

  /// Pretty-print a backend identifier.
  static String _formatBackend(String backend) {
    const labels = {
      'coreaudio': 'CoreAudio',
      'avfoundation': 'AVFoundation',
      'wasapi': 'WASAPI',
      'pulse': 'PulseAudio',
      'pipewire': 'PipeWire',
      'alsa': 'ALSA',
      'jack': 'JACK',
      'oss': 'OSS',
    };
    return labels[backend] ?? backend;
  }

  Widget _buildAudioDeviceView() {
    return StreamBuilder<List<AudioDevice>>(
      stream: widget.player.streams.audioDevices,
      initialData: widget.player.state.audioDevices,
      builder: (context, snapshot) {
        final devices = snapshot.data ?? [];

        return StreamBuilder<AudioDevice>(
          stream: widget.player.streams.audioDevice,
          initialData: widget.player.state.audioDevice,
          builder: (context, selectedSnapshot) {
            final currentDevice = selectedSnapshot.data ?? widget.player.state.audioDevice;

            // Check for duplicate descriptions (same physical device across multiple backends).
            final descCounts = <String, int>{};
            for (final d in devices) {
              final desc = d.description.isEmpty ? d.name : d.description;
              descCounts[desc] = (descCounts[desc] ?? 0) + 1;
            }
            final hasDuplicates = descCounts.values.any((c) => c > 1);

            if (!hasDuplicates) {
              return _buildFlatDeviceList(devices, currentDevice);
            }

            final ungrouped = <AudioDevice>[];
            final groups = <String, List<AudioDevice>>{};
            for (final d in devices) {
              final backend = _audioBackend(d.name);
              if (!d.name.contains('/')) {
                ungrouped.add(d);
              } else {
                (groups[backend] ??= []).add(d);
              }
            }

            return ListView(
              shrinkWrap: true,
              children: [
                for (final d in ungrouped) _buildDeviceTile(d, currentDevice),
                for (final entry in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      _formatBackend(entry.key),
                      style: TextStyle(color: tokens(context).textMuted, fontSize: 12, fontWeight: .w600),
                    ),
                  ),
                  for (final d in entry.value) _buildDeviceTile(d, currentDevice),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildFlatDeviceList(List<AudioDevice> devices, AudioDevice currentDevice) {
    // The device list arrives asynchronously, so an empty list is the normal
    // first frame. Without a placeholder the shrink-wrapped page would render
    // as a bare header and then jump once devices land.
    //
    // A fixed placeholder rather than FiltersBottomSheet's hold-the-outgoing-
    // height technique: this page is entered from the menu, whose height is
    // unrelated to a device list, so holding it would be arbitrary. One small
    // upward move when the devices land beats two.
    if (devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          heightFactor: 1,
          child: Text(t.videoControls.noAudioDevicesAvailable, style: TextStyle(color: tokens(context).textMuted)),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: devices.length,
      itemBuilder: (context, index) => _buildDeviceTile(devices[index], currentDevice),
    );
  }

  Widget _buildDeviceTile(AudioDevice device, AudioDevice currentDevice) {
    final isSelected = device.name == currentDevice.name;
    final label = device.description.isEmpty ? device.name : device.description;

    final primary = Theme.of(context).colorScheme.primary;
    return FocusableListTile(
      title: Text(label, style: TextStyle(color: isSelected ? primary : null)),
      trailing: isSelected ? AppIcon(Symbols.check_rounded, fill: 1, color: primary) : null,
      onTap: () {
        widget.player.setAudioDevice(device);
        OverlaySheetController.of(context).close();
      },
    );
  }

  Widget _buildShaderView() {
    if (_state.shaderService == null) return const SizedBox.shrink();

    return Consumer<ShaderProvider>(
      builder: (context, shaderProvider, _) {
        final currentPreset = _state.shaderService!.currentPreset;
        final presets = shaderProvider.allPresets;

        // +1 for the import button at the end
        return ListView.builder(
          shrinkWrap: true,
          itemCount: presets.length + 1,
          itemBuilder: (context, index) {
            if (index == presets.length) {
              return FocusableListTile(
                leading: AppIcon(Symbols.add_rounded, fill: 1, color: tokens(context).textMuted),
                title: Text(t.shaders.importShader),
                onTap: () => _importCustomShader(shaderProvider),
              );
            }

            final preset = presets[index];
            final isSelected = preset.id == currentPreset.id;
            final isCustom = preset.type == ShaderPresetType.custom;
            final presetName = _shaderPresetTitle(preset);

            return FocusableListTile(
              title: Text(presetName, style: TextStyle(color: isSelected ? Colors.amber : null)),
              subtitle: _getShaderSubtitle(preset) != null
                  ? Text(_getShaderSubtitle(preset)!, style: TextStyle(color: tokens(context).textMuted, fontSize: 12))
                  : null,
              trailing: Row(
                mainAxisSize: .min,
                children: [
                  if (isSelected) const AppIcon(Symbols.check_rounded, fill: 1, color: Colors.amber),
                  if (isCustom) ...[
                    if (isSelected) const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _deleteCustomShader(shaderProvider, preset),
                      child: AppIcon(Symbols.delete_rounded, fill: 1, color: tokens(context).textMuted, size: 20),
                    ),
                  ],
                ],
              ),
              onTap: () async {
                // Disable ambient lighting when selecting a shader
                if (preset.type != ShaderPresetType.none && _state.isAmbientLightingEnabled) {
                  _state.onToggleAmbientLighting?.call();
                }
                await _state.shaderService!.applyPreset(preset);
                await ScopedPlayerPrefs.write(ScopedPlayerPrefs.shaderPreset, _state.metadata, preset.id);
                shaderProvider.setCurrentPreset(preset);
                if (!context.mounted) return;
                _state.onShaderChanged?.call();
                OverlaySheetController.of(context).close();
              },
            );
          },
        );
      },
    );
  }

  Future<void> _importCustomShader(ShaderProvider shaderProvider) async {
    final result = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: ['glsl']);

    if (result == null || result.files.isEmpty || !mounted) return;

    final filePath = result.files.first.path;
    if (filePath == null) return;

    try {
      final displayName = path.basenameWithoutExtension(filePath);
      final preset = await shaderProvider.importCustomShader(filePath, displayName);

      if (_state.shaderService != null && mounted) {
        if (preset.type != ShaderPresetType.none && _state.isAmbientLightingEnabled) {
          _state.onToggleAmbientLighting?.call();
        }
        await _state.shaderService!.applyPreset(preset);
        await ScopedPlayerPrefs.write(ScopedPlayerPrefs.shaderPreset, _state.metadata, preset.id);
        shaderProvider.setCurrentPreset(preset);
        if (!mounted) return;
        _state.onShaderChanged?.call();
      }

      if (mounted) showSuccessSnackBar(context, t.shaders.shaderImported);
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.shaders.shaderImportFailed);
    }
  }

  Future<void> _deleteCustomShader(ShaderProvider shaderProvider, ShaderPreset preset) async {
    final confirmed = await showDeleteConfirmation(
      context,
      title: t.shaders.deleteShader,
      message: t.shaders.deleteShaderConfirm(name: preset.name),
    );
    if (!confirmed || !mounted) return;

    // If the deleted shader is active, clear it from the player first
    if (_state.shaderService!.currentPreset.id == preset.id) {
      await _state.shaderService!.applyPreset(ShaderPreset.none);
      if (mounted) _state.onShaderChanged?.call();
    }

    await shaderProvider.deleteCustomShader(preset);
  }

  String _artcnnVariantLabel(ArtCNNVariant variant) => switch (variant) {
    ArtCNNVariant.neutral => t.shaders.artcnnVariantNeutral,
    ArtCNNVariant.denoise => t.shaders.artcnnVariantDenoise,
    ArtCNNVariant.denoiseSharpen => t.shaders.artcnnVariantDenoiseSharpen,
  };

  String _anime4kQualityLabel(Anime4KQuality quality) =>
      quality == Anime4KQuality.fast ? t.shaders.qualityFast : t.shaders.qualityHQ;

  /// Localized tile title for [preset]. [ShaderPreset.name] is a stable non-localized identity string, so built-in
  /// presets are re-composed here with translated variant/quality words; `ArtCNN`/`Anime4K` and the model/mode labels
  /// are upstream shader identities and stay verbatim.
  String _shaderPresetTitle(ShaderPreset preset) {
    switch (preset.type) {
      case ShaderPresetType.none:
        return t.common.off;
      case ShaderPresetType.artcnn:
        final config = preset.artcnnConfig;
        if (config == null) return preset.name;
        if (config.variant == ArtCNNVariant.neutral) return 'ArtCNN ${config.model.label}';
        return 'ArtCNN ${config.model.label} ${_artcnnVariantLabel(config.variant)}';
      case ShaderPresetType.anime4k:
        final config = preset.anime4kConfig;
        if (config == null) return preset.name;
        return 'Anime4K ${_anime4kQualityLabel(config.quality)} ${config.mode.label}';
      case ShaderPresetType.nvscaler:
      case ShaderPresetType.custom:
        return preset.name;
    }
  }

  String? _getShaderSubtitle(ShaderPreset preset) {
    switch (preset.type) {
      case ShaderPresetType.none:
        return t.shaders.noShaderDescription;
      case ShaderPresetType.nvscaler:
        return t.shaders.nvscalerDescription;
      case ShaderPresetType.artcnn:
        if (preset.artcnnConfig != null) {
          final variant = _artcnnVariantLabel(preset.artcnnConfig!.variant);
          return '${preset.artcnnModelDisplayName} - $variant';
        }
        return null;
      case ShaderPresetType.anime4k:
        if (preset.anime4kConfig != null) {
          final quality = _anime4kQualityLabel(preset.anime4kConfig!.quality);
          final mode = preset.modeDisplayName;
          return '$quality - ${t.shaders.mode} $mode';
        }
        return null;
      case ShaderPresetType.custom:
        return t.shaders.customShaderDescription;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sleepTimer = SleepTimerService();
    final isShaderActive = _state.shaderService != null && _state.shaderService!.currentPreset.isEnabled;
    final isZoomActive = (_zoomScale - 1.0).abs() > 0.0001;
    final isIconActive =
        _currentView == _SettingsView.menu &&
        (sleepTimer.isActive || _audioSyncOffset != 0 || _subtitleSyncOffset != 0 || isShaderActive || isZoomActive);

    return BaseVideoControlSheet(
      title: _getTitle(),
      icon: _getIcon(),
      iconColor: () {
        if (isIconActive) return Colors.amber;
        if (_currentView == _SettingsView.shader && isShaderActive) return Colors.amber;
        return null;
      }(),
      onBack: _currentView != _SettingsView.menu ? _navigateBack : null,
      child: () {
        switch (_currentView) {
          case _SettingsView.menu:
            return _buildMenuView();
          case _SettingsView.speed:
            return _buildSpeedView();
          case _SettingsView.zoom:
            return _buildZoomView();
          case _SettingsView.picture:
            return _buildPictureView();
          case _SettingsView.pictureChannel:
            return _buildPictureChannelView();
          case _SettingsView.versionQuality:
            return _buildVersionQualityView();
          case _SettingsView.sleep:
            return _buildSleepView();
          case _SettingsView.audioDevice:
            return _buildAudioDeviceView();
          case _SettingsView.shader:
            return _buildShaderView();
          case _SettingsView.dvConversion:
            return _buildDvConversionView();
          case _SettingsView.hdrToneMapping:
            return _buildHdrToneMappingView();
          case _SettingsView.subtitleRate:
            return _buildSubtitleRateView();
          case _SettingsView.repeatQueue:
            return _buildRepeatQueueView();
          case _SettingsView.dialogueBoostGain:
            return _buildDbPickerView(
              pref: SettingsService.dialogueBoostGain,
              values: const [3, 6, 9, 12],
              apply: (gainDb) => widget.player.setDialogueBoost(enabled: true, gainDb: gainDb),
            );
          case _SettingsView.downmixCenterBoost:
            return _buildDbPickerView(
              pref: SettingsService.downmixCenterBoost,
              values: const [0, 2, 4, 6, 8, 10, 12],
              apply: (centerBoostDb) => widget.player.setAudioDownmix(
                enabled: true,
                centerBoostDb: centerBoostDb,
                normalize: SettingsService.instance.read(SettingsService.audioDownmixNormalize),
              ),
            );
        }
      }(),
    );
  }
}

/// Compact sync bar shown at the top of the screen so subtitles remain visible.
class _CompactSyncBar extends StatefulWidget {
  final String title;
  final IconData icon;
  final Player player;
  final String propertyName;
  final int initialOffset;
  final Future<void> Function(int offset) onOffsetChanged;
  final FocusNode sliderFocusNode;

  const _CompactSyncBar({
    required this.title,
    required this.icon,
    required this.player,
    required this.propertyName,
    required this.initialOffset,
    required this.onOffsetChanged,
    required this.sliderFocusNode,
  });

  @override
  State<_CompactSyncBar> createState() => _CompactSyncBarState();
}

class _CompactSyncBarState extends State<_CompactSyncBar> {
  final _resetFocusNode = FocusNode(debugLabel: 'SyncResetButton');
  final _closeFocusNode = FocusNode(debugLabel: 'SyncCloseButton');

  @override
  void dispose() {
    _resetFocusNode.dispose();
    _closeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 16),
        AppIcon(widget.icon, fill: 1, color: tokens(context).textMuted, size: 20),
        const SizedBox(width: 8),
        Text(widget.title, style: const TextStyle(fontWeight: .w600, fontSize: 14)),
        Expanded(
          child: SyncOffsetControl(
            player: widget.player,
            propertyName: widget.propertyName,
            initialOffset: widget.initialOffset,
            onOffsetChanged: widget.onOffsetChanged,
            sliderFocusNode: widget.sliderFocusNode,
            resetFocusNode: _resetFocusNode,
            closeFocusNode: _closeFocusNode,
          ),
        ),
        const SizedBox(width: 8),
        FocusableWrapper(
          focusNode: _closeFocusNode,
          onSelect: () => OverlaySheetController.of(context).close(),
          onNavigateLeft: () => _resetFocusNode.requestFocus(),
          borderRadius: 18,
          autoScroll: false,
          useBackgroundFocus: true,
          child: GestureDetector(
            onTap: () => OverlaySheetController.of(context).close(),
            child: Container(
              width: 36,
              height: 36,
              alignment: .center,
              child: AppIcon(Symbols.close_rounded, fill: 1, color: tokens(context).textMuted, size: 22),
            ),
          ),
        ),
        const SizedBox(width: 12),
      ],
    );
  }
}
