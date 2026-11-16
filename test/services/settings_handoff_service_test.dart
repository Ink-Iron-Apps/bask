import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_handoff_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.plezy/settings_handoff');
  late List<MethodCall> calls;
  Object? Function(MethodCall call)? respond;

  setUp(() {
    calls = [];
    respond = null;
    // The gate is Android-only in production; forcing it on keeps these
    // cases running on the Linux and Windows hosts the suite actually uses.
    SettingsHandoffService.debugSupportedOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final handler = respond;
      if (handler == null) return null;
      return handler(call);
    });
  });

  tearDown(() {
    SettingsHandoffService.debugSupportedOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('a predecessor holding settings is reported with when it wrote them', () async {
    respond = (_) => {
      'payload': '{"formatVersion": 1, "prefs": {}}',
      'writtenAt': DateTime.utc(2026, 3, 4).millisecondsSinceEpoch,
      'authority': 'com.inknironapps.plexy.settingshandoff',
    };

    final result = await SettingsHandoffService.readFromPreviousInstall();

    expect(result?.payload, contains('formatVersion'));
    expect(result?.writtenAt, DateTime.utc(2026, 3, 4));
    expect(result?.authority, 'com.inknironapps.plexy.settingshandoff');
    expect(calls.single.method, 'readPreviousInstallSettings');
    expect(calls.single.arguments, {'authorities': SettingsHandoffService.legacyAuthorities});
  });

  test('no predecessor reads as nothing to offer', () async {
    respond = (_) => null;

    expect(await SettingsHandoffService.readFromPreviousInstall(), isNull);
  });

  test('a predecessor with an empty payload is not a source', () async {
    respond = (_) => {'payload': '', 'writtenAt': 0};

    expect(await SettingsHandoffService.readFromPreviousInstall(), isNull);
  });

  test('a refusing or failing provider is swallowed, never surfaced', () async {
    respond = (_) => throw PlatformException(code: 'refused');

    expect(await SettingsHandoffService.readFromPreviousInstall(), isNull);
  });

  test('an empty authority list asks nothing', () async {
    expect(await SettingsHandoffService.readFromPreviousInstall(authorities: const []), isNull);
    expect(calls, isEmpty);
  });

  test('the pre-rename authority is still listed, since that install may hold the settings', () {
    // Entries are only ever added here: an install left behind by an earlier
    // rename is exactly the one worth asking.
    expect(SettingsHandoffService.legacyAuthorities, contains('com.inknironapps.plexy.settingshandoff'));
  });
}
