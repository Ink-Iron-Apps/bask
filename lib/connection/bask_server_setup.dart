import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../exceptions/media_server_exceptions.dart';
import '../i18n/strings.g.dart';
import '../services/plex_auth_service.dart';
import '../utils/app_logger.dart';
import '../utils/log_redaction_manager.dart';
import '../utils/media_server_http_client.dart';
import '../utils/media_server_timeouts.dart';
import '../utils/url_utils.dart';
import 'connection.dart';

/// What `/identity` says about a server that speaks the Plex dialect.
typedef DirectServerIdentity = ({String machineIdentifier, String name, String version});

/// Adds a server that speaks the Plex dialect without belonging to a Plex
/// account — Bask Media Server, which issues its own tokens.
///
/// There is nothing to discover: the user knows the address and holds a token,
/// so the flow is a probe and a credential check rather than an OAuth round
/// trip. The result is an ordinary [PlexAccountConnection] carrying one
/// [PlexServer], marked [PlexAccountConnection.direct] so nothing downstream
/// reaches for plex.tv on its behalf.
class BaskServerSetup {
  BaskServerSetup({@visibleForTesting this._httpClientFactory});

  /// Supplies the transport, so a test can answer a probe with no server on
  /// the other end of it.
  final http.Client Function()? _httpClientFactory;

  MediaServerHttpClient _client(String baseUrl) {
    LogRedactionManager.registerServerUrl(baseUrl);
    return MediaServerHttpClient(baseUrl: baseUrl, client: _httpClientFactory?.call());
  }

  /// Read a server's identity from the unauthenticated `/identity` route.
  ///
  /// Unauthenticated on purpose: a wrong address and a wrong token are
  /// different mistakes, and a viewer who is told "could not reach that
  /// address" when the address was right has been sent to fix the wrong thing.
  Future<DirectServerIdentity> probe(String baseUrl, {Duration timeout = MediaServerTimeouts.plexProbe}) async {
    final normalised = canonicalizeBaseUrl(baseUrl);
    final client = _client(normalised);
    try {
      final response = await client.get('/identity', headers: const {'Accept': 'application/json'}, timeout: timeout);
      throwIfHttpError(response);
      final container = _mediaContainer(response.data);
      final machineIdentifier = (container['machineIdentifier'] as String?)?.trim() ?? '';
      if (machineIdentifier.isEmpty) {
        // It answered, and with something else. A reverse proxy in front of an
        // unrelated app is the usual cause, and it is worth saying so rather
        // than reporting a transport failure that did not happen.
        throw MediaServerUrlException('/identity carried no machineIdentifier', display: t.addServer.notADirectServer);
      }
      final name = (container['friendlyName'] as String?)?.trim() ?? '';
      return (
        machineIdentifier: machineIdentifier,
        name: name.isEmpty ? t.addServer.directServerFallbackName : name,
        version: (container['version'] as String?)?.trim() ?? '',
      );
    } on MediaServerException {
      rethrow;
    } on TimeoutException {
      throw MediaServerUrlException('Server did not respond in time', display: t.addServer.serverTimedOut);
    } catch (error) {
      throw MediaServerUrlException('Server probe failed: $error', display: t.addServer.probeFailed(error: error));
    } finally {
      client.close();
    }
  }

  /// Check that [token] is one this server accepts.
  ///
  /// Against the root `MediaContainer` rather than `/identity`, which answers
  /// the same to everybody: a check that passes without the token proves
  /// nothing, and the viewer would find out at the first real request instead.
  Future<void> checkToken({
    required String baseUrl,
    required String token,
    Duration timeout = MediaServerTimeouts.plexProbe,
  }) async {
    final client = _client(canonicalizeBaseUrl(baseUrl));
    try {
      final response = await client.get(
        '/',
        headers: {'Accept': 'application/json', 'X-Plex-Token': token},
        timeout: timeout,
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw MediaServerAuthException(
          'Server rejected the token (${response.statusCode})',
          statusCode: response.statusCode,
          display: t.addServer.tokenRejected,
        );
      }
      throwIfHttpError(response);
    } on MediaServerException {
      rethrow;
    } on TimeoutException {
      throw MediaServerUrlException('Server did not respond in time', display: t.addServer.serverTimedOut);
    } catch (error) {
      throw MediaServerUrlException('Token check failed: $error', display: t.addServer.probeFailed(error: error));
    } finally {
      client.close();
    }
  }

  /// Probe [baseUrl], check [token] against it, and assemble the connection.
  ///
  /// The row is keyed by the server's machine identifier, so adding the same
  /// server twice -- at a second address, or after a token was reissued --
  /// updates the one row rather than growing another.
  Future<PlexAccountConnection> build({
    required String baseUrl,
    required String token,
    required String clientIdentifier,
  }) async {
    final identity = await probe(baseUrl);
    await checkToken(baseUrl: baseUrl, token: token);

    final server = PlexServer.direct(
      name: identity.name,
      clientIdentifier: identity.machineIdentifier,
      accessToken: token,
      endpoint: canonicalizeBaseUrl(baseUrl),
      product: t.addServer.directServerFallbackName,
      platform: identity.version.isEmpty ? null : identity.version,
    );
    if (server == null) {
      // The form validates the address with the same parser, so reaching here
      // means the probe followed something the candidate list cannot hold.
      throw MediaServerUrlException('Endpoint is not usable: $baseUrl', display: t.addServer.enterDirectServerUrl);
    }

    appLogger.i('Adding direct server ${identity.machineIdentifier} (${identity.name})');
    final now = DateTime.now();
    return PlexAccountConnection(
      id: 'direct.${identity.machineIdentifier}',
      accountToken: token,
      clientIdentifier: clientIdentifier,
      accountLabel: identity.name,
      servers: [server],
      direct: true,
      createdAt: now,
      lastAuthenticatedAt: now,
    );
  }

  /// Whether the address field holds something this can use. Shared with the
  /// form so what it accepts and what [build] can assemble cannot diverge.
  static bool isValidUrl(String raw) => PlexServer.isValidCustomEndpoint(canonicalizeBaseUrl(raw));

  static Map<String, Object?> _mediaContainer(Object? data) {
    if (data is! Map) {
      throw MediaServerUrlException('Response was not JSON', display: t.addServer.responseNotJson);
    }
    final container = data['MediaContainer'];
    if (container is Map) return container.cast<String, Object?>();
    // Plex wraps a JSON MediaContainer in its own name; something that does
    // not is not speaking this dialect, whatever else it is.
    throw MediaServerUrlException('Response had no MediaContainer', display: t.addServer.notADirectServer);
  }
}
