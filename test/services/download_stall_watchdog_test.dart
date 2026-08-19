import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/download_stall_watchdog.dart';

void main() {
  late DateTime now;
  late List<String> restarted;

  DownloadStallWatchdog build({Duration threshold = const Duration(minutes: 2)}) => DownloadStallWatchdog(
    onStalled: (globalKey) async => restarted.add(globalKey),
    threshold: threshold,
    clock: () => now,
  );

  setUp(() {
    now = DateTime(2026, 8, 19, 9);
    restarted = [];
  });

  test('a download reporting progress is not stalled', () async {
    final watchdog = build()..markAlive('srv:1');
    addTearDown(watchdog.dispose);

    now = now.add(const Duration(minutes: 5));
    watchdog.markAlive('srv:1');
    now = now.add(const Duration(seconds: 30));

    await watchdog.checkNow();

    expect(restarted, isEmpty);
  });

  test('a download that has gone quiet past the threshold is restarted', () async {
    // The socket stays open and the platform reports nothing, so silence is the
    // only symptom available.
    final watchdog = build()..markAlive('srv:1');
    addTearDown(watchdog.dispose);

    now = now.add(const Duration(minutes: 2, seconds: 1));
    await watchdog.checkNow();

    expect(restarted, ['srv:1']);
  });

  test('silence shorter than the threshold is left alone', () async {
    final watchdog = build()..markAlive('srv:1');
    addTearDown(watchdog.dispose);

    now = now.add(const Duration(minutes: 1, seconds: 59));
    await watchdog.checkNow();

    expect(restarted, isEmpty);
  });

  test('a stalled download is reported once, not on every sweep', () async {
    final watchdog = build()..markAlive('srv:1');
    addTearDown(watchdog.dispose);

    now = now.add(const Duration(minutes: 3));
    await watchdog.checkNow();
    await watchdog.checkNow();
    await watchdog.checkNow();

    expect(restarted, ['srv:1']);
  });

  test('a restarted download that reports progress can stall again', () async {
    final watchdog = build()..markAlive('srv:1');
    addTearDown(watchdog.dispose);

    now = now.add(const Duration(minutes: 3));
    await watchdog.checkNow();

    // The replacement task starts and reports progress.
    watchdog.markAlive('srv:1');
    now = now.add(const Duration(minutes: 3));
    await watchdog.checkNow();

    expect(restarted, ['srv:1', 'srv:1']);
  });

  test('only the quiet download is restarted', () async {
    final watchdog = build()
      ..markAlive('srv:quiet')
      ..markAlive('srv:busy');
    addTearDown(watchdog.dispose);

    now = now.add(const Duration(minutes: 1, seconds: 30));
    watchdog.markAlive('srv:busy');
    now = now.add(const Duration(minutes: 1, seconds: 30));

    await watchdog.checkNow();

    expect(restarted, ['srv:quiet']);
  });

  test('a forgotten download is never restarted', () async {
    final watchdog = build()..markAlive('srv:1');
    addTearDown(watchdog.dispose);

    watchdog.forget('srv:1');
    now = now.add(const Duration(hours: 1));
    await watchdog.checkNow();

    expect(restarted, isEmpty);
    expect(watchdog.watchedKeys, isEmpty);
  });

  test('finishing one download leaves the others watched', () async {
    final watchdog = build()
      ..markAlive('srv:1')
      ..markAlive('srv:2');
    addTearDown(watchdog.dispose);

    watchdog.forget('srv:1');
    now = now.add(const Duration(minutes: 3));
    await watchdog.checkNow();

    expect(restarted, ['srv:2']);
  });
}
