import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/transport_keys.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// Clicking the picture to play and pause is on by default, but only where
/// the pointer is a mouse.
///
/// A click means "do the thing", and the controls are a mouse movement away.
/// A tap means "show me the controls", and on a touch screen there is no
/// pointer movement to raise them with — so defaulting it on there would take
/// the seek bar away with no gesture left to get it back. Touch therefore
/// honours the preference only once the viewer has set it themselves.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late SettingsService settings;
  late List<TransportCommand> transportCommands;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(false);
    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _RecordingPlayer();
    chrome = PlayerChromeController();
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
    transportCommands = [];
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await database.close();
  });

  Future<void> pumpControls(WidgetTester tester, {required bool desktop}) async {
    PlatformDetector.debugSetIsDesktopOSOverride(desktop);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
        ],
        child: MaterialApp(
          theme: ThemeData(
            platform: desktop ? TargetPlatform.windows : TargetPlatform.android,
            extensions: const [testMonoTokens],
          ),
          home: Scaffold(
            body: SizedBox(
              // A phone-sized surface is what makes PlatformDetector.isMobile
              // true for the touch cases.
              width: desktop ? 1280 : 420,
              height: desktop ? 720 : 800,
              child: PlexVideoControls(
                player: player,
                volumeController: volume,
                metadata: testMediaItem(id: 'click-to-play'),
                toastController: toast,
                chromeController: chrome,
                canNavigateMediaItems: false,
                videoZoomScale: 1.0,
                onPlayPauseRequested: (command) async {
                  transportCommands.add(command);
                  await player.playOrPause();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    chrome.hide();
    chrome.markControlsHidden();
    await tester.pump();
    expect(chrome.controlsVisible, isFalse);
  }

  Future<void> settle(WidgetTester tester) async {
    chrome.cancelAutoHide();
    toast.hide();
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('a mouse click plays and pauses with nothing stored', (tester) async {
    await pumpControls(tester, desktop: true);

    await tester.tapAt(tester.getRect(find.byType(PlexVideoControls)).center);
    await tester.pump();

    expect(transportCommands, [TransportCommand.toggle]);

    await settle(tester);
  });

  testWidgets('a touch tap still raises the controls with nothing stored', (tester) async {
    await pumpControls(tester, desktop: false);

    await tester.tapAt(tester.getRect(find.byType(PlexVideoControls)).center);
    await tester.pump();

    expect(transportCommands, isEmpty, reason: 'nothing else on a phone would bring the controls back');
    expect(chrome.controlsVisible, isTrue);

    await settle(tester);
  });

  testWidgets('a touch tap plays and pauses once the viewer asks for it', (tester) async {
    await settings.write(SettingsService.clickVideoTogglesPlayback, true);
    await pumpControls(tester, desktop: false);

    await tester.tapAt(tester.getRect(find.byType(PlexVideoControls)).center);
    await tester.pump();

    expect(transportCommands, [TransportCommand.toggle]);
    expect(chrome.controlsVisible, isFalse);

    await settle(tester);
  });

  testWidgets('turning it off leaves the mouse click on the controls', (tester) async {
    await settings.write(SettingsService.clickVideoTogglesPlayback, false);
    await pumpControls(tester, desktop: true);

    await tester.tapAt(tester.getRect(find.byType(PlexVideoControls)).center);
    await tester.pump();

    expect(transportCommands, isEmpty);
    expect(chrome.controlsVisible, isTrue);

    await settle(tester);
  });
}

/// Minimal [Player] tracking playback state against a fixed 45-minute item.
class _RecordingPlayer implements Player {
  bool _playing = true;

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state => PlayerState(
    playing: _playing,
    position: const Duration(minutes: 10),
    duration: const Duration(minutes: 45),
    seekable: true,
  );

  @override
  PlayerStreams get streams => PlayerStreams(
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: const Stream<Duration>.empty(),
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
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> playOrPause() async => _playing = !_playing;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
