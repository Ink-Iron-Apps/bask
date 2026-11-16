import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:bask/database/app_database.dart';
import 'package:bask/focus/input_mode_tracker.dart';
import 'package:bask/i18n/strings.g.dart';
import 'package:bask/media/media_source_info.dart';
import 'package:bask/mpv/mpv.dart';
import 'package:bask/providers/playback_state_provider.dart';
import 'package:bask/services/settings_service.dart';
import 'package:bask/services/video_volume_controller.dart';
import 'package:bask/utils/platform_detector.dart';
import 'package:bask/watch_together/providers/watch_together_provider.dart';
import 'package:bask/widgets/video_controls/player_chrome_controller.dart';
import 'package:bask/widgets/video_controls/video_controls.dart';
import 'package:bask/widgets/video_controls/widgets/player_toast_indicator.dart';
import 'package:bask/widgets/video_controls/widgets/skip_marker_button.dart';
import 'package:bask/focus/dpad_navigator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// A skip button that hid before the viewer reached it comes back focused.
///
/// The button retires itself after seven seconds, and on a TV the chrome is
/// down by then too. Raising the chrome already brought the button back on
/// screen, but focus landed on Play/Pause, so the viewer had to arrow across
/// the OSD to reach the one control with a deadline on it while the intro
/// played on. A D-pad press is the "give it back to me" gesture: the skip
/// button takes the focus whenever it is showing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TogglePlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late ValueNotifier<bool> hasFirstFrame;
  late SettingsService settings;
  late FocusNode screenFocusNode;
  var toggles = 0;

  /// What the player screen would have done with each Back that escaped the
  /// controls. The harness cannot run the real staged chain, so it records the
  /// disposition the screen would have resolved: an empty list means the
  /// controls answered the press themselves.
  final screenBackDispositions = <PlayerBackDisposition>[];

  Future<void> setNavigationEnabled(bool value) => settings.write(SettingsService.videoPlayerNavigationEnabled, value);

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();

    // Desktop with a pointer: the configuration the report came from.
    TvDetectionService.debugSetAppleTVOverride(false);
    PlatformDetector.debugSetIsDesktopOSOverride(true);

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _TogglePlayer();
    chrome = PlayerChromeController(initiallyVisible: false);
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
    hasFirstFrame = ValueNotifier<bool>(true);
    screenFocusNode = FocusNode(debugLabel: 'VideoPlayerScreen');
    toggles = 0;
    screenBackDispositions.clear();
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    TvDetectionService.setForceTVSync(false);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    hasFirstFrame.dispose();
    screenFocusNode.dispose();
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await player.close();
    await database.close();
  });

  /// Mirrors the production tree: the screen-level node autofocuses during the
  /// loading phase and already holds the remote by the time the controls mount,
  /// so the controls' own `autofocus` cannot win it back. Without that, the
  /// surface would take focus by default and the startup claim would look
  /// correct even when it is not.
  Widget shell(Widget child, {TargetPlatform platform = TargetPlatform.windows}) => InputModeTracker(
    child: MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: database),
        ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
        ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: platform, extensions: const [testMonoTokens]),
        home: Scaffold(
          body: SizedBox(
            width: 1280,
            height: 720,
            child: Focus(
              focusNode: screenFocusNode,
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is KeyUpEvent && event.logicalKey.isBackKey) {
                  screenBackDispositions.add(
                    resolvePlayerBackDisposition(
                      navigationKey: classifyPlayerNavigationKey(event, isAppleTV: PlatformDetector.isAppleTV()),
                      contentStripVisible: chrome.contentStripVisible,
                      controlsVisible: chrome.controlsVisible,
                      physicalEscapeExitsFullscreen: false,
                    ),
                  );
                }
                return KeyEventResult.ignored;
              },
              child: child,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPlayer(
    WidgetTester tester, {
    List<MediaMarker>? markers,
    TargetPlatform platform = TargetPlatform.windows,
    bool canControl = true,
    bool playbackPromptOpen = false,
  }) async {
    await tester.pumpWidget(shell(const SizedBox.expand(), platform: platform));
    await tester.pump();
    expect(screenFocusNode.hasPrimaryFocus, isTrue, reason: 'precondition: the screen node owns the remote');

    await tester.pumpWidget(
      shell(
        platform: platform,
        PlexVideoControls(
          player: player,
          volumeController: volume,
          metadata: testMediaItem(id: 'select-key'),
          initialMarkers: markers,
          toastController: toast,
          chromeController: chrome,
          hasFirstFrame: hasFirstFrame,
          canNavigateMediaItems: false,
          canControl: canControl,
          playbackPromptOpen: playbackPromptOpen,
          onPlayPauseRequested: (_) async => toggles++,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(key);
    await tester.pump();
    await tester.sendKeyUpEvent(key);
    await tester.pumpAndSettle();
  }

  String? focusLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  /// Mounts the player, runs [body], then unmounts and disarms the auto-hide
  /// timer so the harness's pending-timer check stays honest.
  void playerTest(
    String description,
    Future<void> Function(WidgetTester tester) body, {
    List<MediaMarker>? markers,
    TargetPlatform platform = TargetPlatform.windows,
    bool canControl = true,
    bool playbackPromptOpen = false,
  }) {
    testWidgets(description, (tester) async {
      await pumpPlayer(
        tester,
        markers: markers,
        platform: platform,
        canControl: canControl,
        playbackPromptOpen: playbackPromptOpen,
      );
      await body(tester);
      chrome.cancelAutoHide();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  group('a dismissed skip button on TV', () {
    final introMarker = MediaMarker(id: 1, type: 'intro', startTimeOffset: 10000, endTimeOffset: 120000);

    setUp(() async {
      // A TV with player navigation on and a remote in hand: the arrangement
      // the report came from.
      TvDetectionService.setForceTVSync(true);
      PlatformDetector.debugSetIsDesktopOSOverride(false);
      await setNavigationEnabled(true);
    });

    /// Puts the playhead inside the marker, then lets the button's own
    /// seven-second timer retire it with the chrome down.
    Future<void> letTheButtonHide(WidgetTester tester) async {
      InputModeTracker.reportNonPointerInput();
      player.emitPosition(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(find.byType(SkipMarkerButton), findsOneWidget, reason: 'precondition: the button appeared');

      chrome.hide();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(find.byType(SkipMarkerButton), findsNothing, reason: 'precondition: it retired itself');
    }

    playerTest('a D-pad press brings it back with the remote on it', markers: [introMarker], (tester) async {
      await letTheButtonHide(tester);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(chrome.controlsVisible, isTrue);
      expect(find.byType(SkipMarkerButton), findsOneWidget, reason: 'still inside the marker');
      expect(focusLabel(), 'SkipMarkerButton', reason: 'the control with a deadline takes the focus');

      await press(tester, LogicalKeyboardKey.select);

      expect(player.state.position, const Duration(seconds: 120), reason: 'one press skipped the intro');
    });

    playerTest('Tab into the OSD lands there too', markers: [introMarker], (tester) async {
      await letTheButtonHide(tester);

      await press(tester, LogicalKeyboardKey.tab);

      expect(focusLabel(), 'SkipMarkerButton');
    });

    playerTest('past the marker the chrome opens on Play/Pause as before', markers: [introMarker], (tester) async {
      await letTheButtonHide(tester);
      player.emitPosition(const Duration(seconds: 200));
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(chrome.controlsVisible, isTrue);
      expect(find.byType(SkipMarkerButton), findsNothing);
      expect(focusLabel(), isNot('SkipMarkerButton'), reason: 'nothing to skip, so the default stands');
    });
  });
}

/// Minimal [Player] reporting steady playback; transport is routed to the
/// widget's `onPlayPauseRequested` callback so the test can count toggles.
class _TogglePlayer implements Player {
  Duration _position = const Duration(minutes: 5);
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();

  /// Moves the playhead and announces it on the position stream, the way a
  /// real player drives marker detection.
  void emitPosition(Duration position) {
    _position = position;
    _positionController.add(position);
  }

  Future<void> close() => _positionController.close();

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state =>
      PlayerState(playing: true, position: _position, duration: const Duration(minutes: 45), seekable: true);

  /// A real player announces the new playhead right after a seek; marker
  /// detection (and its focus handling) rides on that event.
  @override
  Future<void> seek(Duration position) async => emitPosition(position);

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: _positionController.stream,
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: const Stream<TrackSelection>.empty(),
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: const Stream<void>.empty(),
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
