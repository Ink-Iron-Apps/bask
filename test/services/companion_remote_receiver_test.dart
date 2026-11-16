import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bask/models/companion_remote/remote_command.dart';
import 'package:bask/services/companion_remote/companion_remote_receiver.dart';
import 'package:bask/widgets/video_controls/player_chrome_controller.dart';
import 'package:bask/widgets/video_controls/video_controls.dart';

void main() {
  testWidgets('Back command dispatches semantic gamepad B events', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final events = <KeyEvent>[];
    var actions = 0;
    var exits = 0;
    final chromeController = PlayerChromeController();
    addTearDown(chromeController.dispose);
    final coordinator = PlayerNavigationCoordinator(
      chromeController: chromeController,
      isPromptOpen: () => false,
      dismissPrompt: () {},
      isChromePresented: () => chromeController.controlsPresented,
      exitFullscreenIfActive: () async => false,
      exitPlayer: () => exits++,
      navigateHome: () {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          focusNode: focusNode,
          onKeyEvent: (_, event) {
            events.add(event);
            final navigationKey = classifyPlayerNavigationKey(event, isAppleTV: false);
            return handlePlayerNavigationKeyAction(event, navigationKey, () {
              actions++;
              coordinator.handle(navigationKey);
            });
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();

    CompanionRemoteReceiver.instance.handleCommand(const RemoteCommand(type: RemoteCommandType.back), null);
    await tester.pump();

    expect(events, hasLength(2));
    expect(events.first, isA<KeyDownEvent>());
    expect(events.last, isA<KeyUpEvent>());
    expect(events.map((event) => event.logicalKey), everyElement(LogicalKeyboardKey.gameButtonB));
    expect(events.map((event) => event.deviceType), everyElement(ui.KeyEventDeviceType.directionalPad));
    expect(actions, 1);
    expect(chromeController.controlsVisible, isFalse);
    expect(exits, 0);
  });

  test('playMedia hands the host the item the phone picked', () {
    final received = <(String, String)>[];
    final receiver = CompanionRemoteReceiver.instance;
    receiver.onPlayMedia = (serverId, ratingKey) => received.add((serverId, ratingKey));
    addTearDown(() => receiver.onPlayMedia = null);

    receiver.handleCommand(
      const RemoteCommand(type: RemoteCommandType.playMedia, data: {'serverId': 'abc', 'ratingKey': '1234'}),
      null,
    );

    expect(received, [('abc', '1234')]);
  });

  test('playMedia without an item is ignored rather than played', () {
    // A malformed frame must not start something arbitrary on a screen the
    // user is not holding.
    var calls = 0;
    final receiver = CompanionRemoteReceiver.instance;
    receiver.onPlayMedia = (_, _) => calls++;
    addTearDown(() => receiver.onPlayMedia = null);

    receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.playMedia), null);
    receiver.handleCommand(const RemoteCommand(type: RemoteCommandType.playMedia, data: {'serverId': 'abc'}), null);

    expect(calls, 0);
  });
}
