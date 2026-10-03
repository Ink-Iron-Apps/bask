import 'dart:io';

import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

/// What the platform says about the active network's cost.
class NetworkMeteredState {
  const NetworkMeteredState({
    required this.metered,
    this.hasWifi = false,
    this.hasCellular = false,
    this.hasEthernet = false,
    this.hasVpn = false,
    this.connected = true,
  });

  /// Null when the platform could not answer; the caller then has only
  /// connectivity_plus to go on.
  final bool? metered;

  final bool hasWifi;
  final bool hasCellular;
  final bool hasEthernet;
  final bool hasVpn;
  final bool connected;

  @override
  String toString() =>
      'metered=$metered wifi=$hasWifi cellular=$hasCellular ethernet=$hasEthernet vpn=$hasVpn connected=$connected';
}

/// Asks Android whether the connection charges for data.
///
/// `connectivity_plus` reports transports, and a VPN hides them: a tunnel over
/// cellular can come back as neither WiFi nor cellular, so a WiFi-only gate
/// that reasons from transports sees an unknown link and allows the download.
/// With an always-on VPN that is the normal state, not an edge case — it is
/// how a WiFi-only device spent twelve gigabytes of cellular data in a day.
///
/// `ConnectivityManager.isActiveNetworkMetered` is the same signal
/// WorkManager's UNMETERED constraint uses, and Android derives it for a VPN
/// from the network underneath it. Platforms without the channel answer null
/// and the caller keeps its old behavior.
class NetworkMeteredProbe {
  NetworkMeteredProbe._();

  static const MethodChannel _channel = MethodChannel('com.plezy/device');

  /// Answers are good for this long. The gate is consulted once per queued
  /// item, and a burst of fifty does not need fifty platform round trips.
  static const Duration cacheFor = Duration(seconds: 5);

  static NetworkMeteredState? _cached;
  static DateTime? _cachedAt;

  static NetworkMeteredState? _override;

  /// Replaces the platform answer in tests.
  static void debugSetStateForTesting(NetworkMeteredState? state) {
    _override = state;
    _cached = null;
    _cachedAt = null;
  }

  static void resetCacheForTesting() {
    _cached = null;
    _cachedAt = null;
  }

  /// The platform's answer, or null where there is none.
  static Future<NetworkMeteredState?> read({DateTime? now}) async {
    if (_override != null) return _override;
    if (!Platform.isAndroid) return null;

    final at = now ?? DateTime.now();
    final cachedAt = _cachedAt;
    if (_cached != null && cachedAt != null && at.difference(cachedAt) < cacheFor) return _cached;

    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('getNetworkMeteredState');
      if (raw == null || raw['available'] != true) return null;

      final state = NetworkMeteredState(
        metered: raw['metered'] as bool?,
        hasWifi: raw['hasWifi'] == true,
        hasCellular: raw['hasCellular'] == true,
        hasEthernet: raw['hasEthernet'] == true,
        hasVpn: raw['hasVpn'] == true,
        connected: raw['connected'] != false,
      );
      _cached = state;
      _cachedAt = at;
      return state;
    } catch (e) {
      // An older build of the app, or a platform without the handler.
      appLogger.d('Network metered state unavailable', error: e);
      return null;
    }
  }
}
