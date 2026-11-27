part of '../../video_player_screen.dart';

extension _VideoPlayerPipMethods on VideoPlayerScreenState {
  void _attachPipStateListener() {
    _releasePipStateListener ??= bindListenable(PipService().isPipActive, _onPipStateChanged);
  }

  void _detachPipStateListener() {
    _releasePipStateListener?.call();
    _releasePipStateListener = null;
  }

  void _clearAutoPipEnteringCallback() {
    final callback = _autoPipEnteringCallback;
    if (callback != null && identical(PipService.onAutoPipEntering, callback)) {
      PipService.onAutoPipEntering = null;
    }
    _autoPipEnteringCallback = null;
  }

  /// Initialize VideoFilterManager and the PiP methods if not already set up.
  /// Called from both live TV and VOD playback paths.
  Future<void> _initVideoFilterAndPip() async {
    final currentPlayer = player;
    if (!mounted || currentPlayer == null) return;
    if (_videoFilterManager != null && _pipInitialized) {
      _attachPipStateListener();
      return;
    }

    final needsVideoFilter = _videoFilterManager == null;
    final settings = needsVideoFilter ? await SettingsService.getInstance() : null;
    if (!mounted || player != currentPlayer) return;
    final initialPlayerSize = _lastVideoLayoutPlayer == currentPlayer ? _lastVideoLayoutSize : null;

    if (needsVideoFilter && _videoFilterManager == null && settings != null) {
      _videoFilterManager = VideoFilterManager(
        player: currentPlayer,
        // iOS/tvOS and macOS zoom the native video layer; mpv's video-zoom
        // would force vo_avfoundation's Core Image path and kill HDR/DV
        // passthrough.
        nativeVideoZoom: Platform.isIOS || Platform.isMacOS,
        initialBoxFitMode: ScopedPlayerPrefs.resolve(ScopedPlayerPrefs.boxFitMode, _currentMetadata),
        initialZoomScale: ScopedPlayerPrefs.resolve(ScopedPlayerPrefs.videoZoom, _currentMetadata),
        initialPlayerSize: initialPlayerSize,
        // Reads _currentMetadata at invocation time so a cycle after an
        // in-place episode swap keys against the item actually on screen.
        onBoxFitModeChanged: (mode) =>
            unawaited(ScopedPlayerPrefs.write(ScopedPlayerPrefs.boxFitMode, _currentMetadata, mode)),
      );
      unawaited(_videoFilterManager!.updateVideoFilter());
    }

    _pipInitialized = true;
    _attachPipStateListener();
  }

  /// Arm auto-PiP for the playback [currentPlayer] just opened: the callback
  /// for the API 26-30 path and the initial native state. A player that
  /// opened already playing reports no later `playing` change for
  /// [_onPlayingStateChanged] to arm it from.
  void _armAutoPip(Player currentPlayer) {
    if (!_autoPipEnabled) return;

    void autoPipEnteringCallback() {
      if (!mounted || player != currentPlayer) return;
      _setAndroidAutoPipTransitionInFlight(true, reason: 'native_auto_pip_entering');
      _preparePipFiltersForEntry();
    }

    _autoPipEnteringCallback = autoPipEnteringCallback;
    PipService.onAutoPipEntering = autoPipEnteringCallback;
    if (currentPlayer.state.playing) {
      unawaited(_updateAutoPipState(isPlaying: true));
    }
  }

  Future<void> _togglePIPMode() async {
    // Desktop has no picture-in-picture to ask the system for, so the same
    // button hands the picture to a corner window inside the app instead and
    // steps this route out of the way.
    if (PlatformDetector.isDesktopOS()) {
      _enterInAppMiniPlayer();
      return;
    }

    if (!_pipInitialized) return;

    final supported = await PipService.isSupported();
    if (!supported) {
      _onPipRequestFailed(t.videoControls.pipErrors.notSupported);
      return;
    }

    // If PiP is already active, exit it
    if (PipService().isPipActive.value) {
      await PipService.exit();
      return;
    }

    // Reset video filter to contain mode before entering PiP. Android, iOS,
    // and macOS all reuse the inline video surface/layer for PiP.
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      if (_pipInitialized) _preparePipFiltersForEntry();
      // Wait a frame for the filter change to take effect
      await Future.delayed(const Duration(milliseconds: 50));
    }

    final dims = await _getVideoDimensions();
    final result = await PipService.enter(width: dims.$1, height: dims.$2);
    if (!result.$1) _onPipRequestFailed(result.$2);
  }

  /// Hand the picture to the corner window and take this route off stage.
  ///
  /// Offstage rather than popped: the route keeps its state, its player and
  /// its progress reporting, stops painting, and — the point — stops
  /// swallowing the clicks meant for the library underneath. The overlay above
  /// the navigator draws the same player, which on a native video surface is
  /// all it takes to move the picture into the corner.
  void _enterInAppMiniPlayer() {
    final currentPlayer = player;
    final route = ModalRoute.of(context);
    if (currentPlayer == null || route == null) return;

    VideoMiniPlayerController.instance.enter(
      player: currentPlayer,
      metadata: _currentMetadata,
      onExpand: _exitInAppMiniPlayer,
      onClose: () {
        _exitInAppMiniPlayer();
        _handleScreenPlayerNavigation(PlayerNavigationKey.back);
      },
    );
    // Order matters: hand the route's opacity over *before* taking it
    // offstage, so the routes below are already allowed to paint in the frame
    // this route stops painting. The other way round leaves one blank frame.
    if (route is VideoPlayerRoute) route.handedToMiniPlayer = true;
    route.offstage = true;
    // Rebuilt explicitly rather than leaning on the route's own setState: the
    // full-screen Video has to stop claiming the native plane in the same
    // frame the overlay starts claiming it.
    setStateIfMounted(() {});
  }

  /// Bring the full-screen player back.
  void _exitInAppMiniPlayer() {
    if (!VideoMiniPlayerController.instance.isActive) return;
    VideoMiniPlayerController.instance.clear();
    if (!mounted) return;
    final route = ModalRoute.of(context);
    route?.offstage = false;
    if (route is VideoPlayerRoute) route.handedToMiniPlayer = false;
    setStateIfMounted(() {});
    // Focus has to be asked for again. The screen reclaims it whenever it
    // loses it, but that listener fired while the subtree was excluded from
    // focus for the corner player's sake, and the request it made then was a
    // no-op. Nothing fires a second time on its own, so the keyboard would
    // land nowhere until the next click.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_isExiting.value) _screenFocusNode.requestFocus();
    });
  }

  void _onPipRequestFailed(String? error) {
    if (!mounted) return;
    _restorePipFiltersAfterExit();
    showErrorSnackBar(context, error ?? t.videoControls.pipFailed);
  }

  Future<void> _updateAutoPipState({required bool isPlaying}) async {
    if (!_pipInitialized) return;

    if (!isPlaying) {
      await PipService.setAutoPipReady(ready: false);
      return;
    }

    final dims = await _getVideoDimensions();
    await PipService.setAutoPipReady(ready: true, width: dims.$1, height: dims.$2);
  }

  /// Get current video dimensions (display or storage or fallback to viewport)
  Future<(int? width, int? height)> _getVideoDimensions() async {
    final currentPlayer = player;
    int? width;
    int? height;

    try {
      final dwidth = await currentPlayer?.getProperty('dwidth');
      final dheight = await currentPlayer?.getProperty('dheight');
      if (dwidth != null && dheight != null) {
        width = int.tryParse(dwidth);
        height = int.tryParse(dheight);
      }
    } catch (e) {
      appLogger.d('PiP: dwidth/dheight unavailable', error: e);
    }

    if (width == null || height == null) {
      try {
        final videoWidth = await currentPlayer?.getProperty('width');
        final videoHeight = await currentPlayer?.getProperty('height');
        if (videoWidth != null && videoHeight != null) {
          width = int.tryParse(videoWidth);
          height = int.tryParse(videoHeight);
        }
      } catch (e) {
        appLogger.d('PiP: width/height unavailable', error: e);
      }
    }

    final viewport = _lastVideoLayoutPlayer == currentPlayer ? _lastVideoLayoutSize : null;
    width ??= viewport?.width.toInt();
    height ??= viewport?.height.toInt();

    return (width, height);
  }

  void _preparePipFiltersForEntry() {
    if (!mounted) return;
    if (_pipFiltersPrepared) return;
    _pipFiltersPrepared = true;
    _videoFilterManager?.enterPipMode();
  }

  void _restorePipFiltersAfterExit() {
    if (!mounted) {
      _pipFiltersPrepared = false;
      return;
    }

    final filterManager = _videoFilterManager;
    if (filterManager == null) {
      _pipFiltersPrepared = false;
      return;
    }

    final restoreAmbient = filterManager.hadAmbientLightingBeforePip;
    filterManager.exitPipMode();
    if (restoreAmbient) {
      filterManager.clearPipAmbientLightingFlag();
      unawaited(_visualEffects.restoreAmbientLighting());
    }
    _pipFiltersPrepared = false;
  }

  /// Handle PiP state changes to restore video scaling when exiting PiP
  void _onPipStateChanged() {
    if (!mounted || player == null) {
      _detachPipStateListener();
      return;
    }

    final isInPip = PipService().isPipActive.value;
    _setAndroidAutoPipTransitionInFlight(false, reason: 'pip_state_changed');
    _recordLifecycleState('pip_state_changed', action: isInPip ? 'entered' : 'exited');

    if (!_pipInitialized || _videoFilterManager == null) return;

    if (isInPip) {
      _preparePipFiltersForEntry();
    } else {
      _restorePipFiltersAfterExit();
    }
  }
}
