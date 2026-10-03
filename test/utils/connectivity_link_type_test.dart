import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/connectivity_link_type.dart';

void main() {
  // The single definition of "metered connection" behind the cellular playback
  // default, the download WiFi-only gate and the sync-rule cooldown.
  group('ConnectivityLinkType', () {
    test('cellular alone is the only metered case', () {
      expect(const [ConnectivityResult.mobile].isCellularOnly, isTrue);
      expect(const [ConnectivityResult.mobile].hasWifiOrEthernet, isFalse);
    });

    test('any WiFi or Ethernet link alongside cellular wins', () {
      for (final unmetered in const [ConnectivityResult.wifi, ConnectivityResult.ethernet]) {
        final results = [ConnectivityResult.mobile, unmetered];
        expect(results.isCellularOnly, isFalse, reason: '$unmetered should outrank cellular');
        expect(results.hasWifiOrEthernet, isTrue);
      }
    });

    test('an unknown snapshot is neither metered nor unmetered', () {
      // Load-bearing: the download WiFi-only gate relies on this instead of a
      // separate empty-list guard, and playback falls back to the general
      // default quality until the connection type is known.
      expect(const <ConnectivityResult>[].isCellularOnly, isFalse);
      expect(const <ConnectivityResult>[].hasWifiOrEthernet, isFalse);
      expect(const [ConnectivityResult.none].isCellularOnly, isFalse);
      expect(const [ConnectivityResult.other].isCellularOnly, isFalse);
    });

    test('cellular under a VPN still reads as metered when the transport shows', () {
      // Android reports the VPN alongside its underlying transport on most
      // devices; when it does, a tunnel must not launder a data connection
      // into an unmetered one.
      expect(const [ConnectivityResult.mobile, ConnectivityResult.vpn].isCellularOnly, isTrue);
      expect(const [ConnectivityResult.wifi, ConnectivityResult.vpn].isCellularOnly, isFalse);
    });

    test('a VPN on its own is an unknown link, not an unmetered one', () {
      // Some devices report only the tunnel, which says nothing about what
      // carries it. This reads as unknown here, so the WiFi-only gate lets the
      // queue through and the platform's own WiFi requirement — applied
      // globally by DownloadManagerService.applyWifiOnlyRequirement — is what
      // holds the transfer.
      expect(const [ConnectivityResult.vpn].isCellularOnly, isFalse);
      expect(const [ConnectivityResult.vpn].hasWifiOrEthernet, isFalse);
    });

    test('a WiFi-only link is unmetered', () {
      expect(const [ConnectivityResult.wifi].hasWifiOrEthernet, isTrue);
      expect(const [ConnectivityResult.wifi].isCellularOnly, isFalse);
    });
  });
}
