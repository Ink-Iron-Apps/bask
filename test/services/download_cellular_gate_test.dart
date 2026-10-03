import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/network_metered_probe.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    NetworkMeteredProbe.debugSetStateForTesting(null);
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.downloadOnWifiOnly, true);
  });

  tearDown(() {
    NetworkMeteredProbe.debugSetStateForTesting(null);
    SettingsService.resetForTesting();
  });

  test('a metered link blocks the queue even when the transports say nothing', () async {
    // An always-on VPN over cellular: connectivity_plus sees only the tunnel,
    // which reads as neither WiFi nor cellular. Reasoning from that let a
    // WiFi-only phone spend twelve gigabytes of data in a day.
    NetworkMeteredProbe.debugSetStateForTesting(const NetworkMeteredState(metered: true, hasVpn: true));

    expect(await DownloadManagerService.shouldBlockDownloadOnCellularWith(const [ConnectivityResult.vpn]), isTrue);
  });

  test('an unmetered link is allowed even when cellular is also up', () async {
    // WiFi plus a cellular radio that is connected but not carrying: the
    // platform knows which one the traffic takes.
    NetworkMeteredProbe.debugSetStateForTesting(
      const NetworkMeteredState(metered: false, hasWifi: true, hasCellular: true),
    );

    expect(
      await DownloadManagerService.shouldBlockDownloadOnCellularWith(const [
        ConnectivityResult.wifi,
        ConnectivityResult.mobile,
      ]),
      isFalse,
    );
  });

  test('without a platform answer it falls back to the transport snapshot', () async {
    NetworkMeteredProbe.debugSetStateForTesting(const NetworkMeteredState(metered: null));

    expect(await DownloadManagerService.shouldBlockDownloadOnCellularWith(const [ConnectivityResult.mobile]), isTrue);
    expect(await DownloadManagerService.shouldBlockDownloadOnCellularWith(const [ConnectivityResult.wifi]), isFalse);
  });

  test('the setting off allows a metered link, without asking the platform', () async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.downloadOnWifiOnly, false);
    NetworkMeteredProbe.debugSetStateForTesting(const NetworkMeteredState(metered: true));

    expect(await DownloadManagerService.shouldBlockDownloadOnCellularWith(const [ConnectivityResult.mobile]), isFalse);
  });
}
