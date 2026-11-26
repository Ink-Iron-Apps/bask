import 'dart:convert';

import 'package:bask/connection/bask_server_setup.dart';
import 'package:bask/connection/connection.dart';
import 'package:bask/exceptions/media_server_exceptions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Adding a server by address and token is the only way to reach a Bask Media
/// Server, so what this accepts and what it refuses is the whole gate.
void main() {
  http.Response identity({String machineIdentifier = 'bms-1', String? friendlyName = 'The house'}) => http.Response(
    jsonEncode({
      'MediaContainer': {'machineIdentifier': machineIdentifier, 'friendlyName': ?friendlyName, 'version': '0.9.1'},
    }),
    200,
    headers: {'content-type': 'application/json'},
  );

  BaskServerSetup setupThat(Future<http.Response> Function(http.Request request) answer) =>
      BaskServerSetup(httpClientFactory: () => MockClient(answer));

  group('probing', () {
    test('reads the machine identifier, name and version off /identity', () async {
      final setup = setupThat((request) async {
        expect(request.url.path, '/identity');
        // Unauthenticated on purpose: a wrong address and a wrong token have
        // to be distinguishable, so the probe carries no token at all.
        expect(request.headers.containsKey('X-Plex-Token'), isFalse);
        return identity();
      });

      final probed = await setup.probe('http://192.168.1.10:32400');

      expect(probed.machineIdentifier, 'bms-1');
      expect(probed.name, 'The house');
      expect(probed.version, '0.9.1');
    });

    test('falls back to a product name when the server has not been named', () async {
      final setup = setupThat((_) async => identity(friendlyName: null));
      expect((await setup.probe('http://192.168.1.10:32400')).name, 'Bask Media Server');
    });

    test('refuses something that answers but is not speaking this dialect', () async {
      final setup = setupThat(
        (_) async => http.Response('{"status":"ok"}', 200, headers: {'content-type': 'application/json'}),
      );

      await expectLater(
        setup.probe('http://192.168.1.10:32400'),
        throwsA(
          isA<MediaServerUrlException>().having(
            (e) => e.display,
            'display',
            'That address answered, but not like a Bask or Plex server.',
          ),
        ),
      );
    });

    test('refuses a MediaContainer with no machine identifier in it', () async {
      final setup = setupThat((_) async => identity(machineIdentifier: ''));
      await expectLater(setup.probe('http://192.168.1.10:32400'), throwsA(isA<MediaServerUrlException>()));
    });
  });

  group('the token', () {
    test('is checked against a route that needs it, carrying the token', () async {
      var checked = false;
      final setup = setupThat((request) async {
        if (request.url.path == '/identity') return identity();
        // The root container, not /identity: /identity answers the same to
        // everybody, so checking it would pass with no token at all.
        expect(request.url.path, '/');
        expect(request.headers['X-Plex-Token'], 'a-real-token');
        checked = true;
        return http.Response(
          jsonEncode({
            'MediaContainer': {'size': 0},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await setup.checkToken(baseUrl: 'http://192.168.1.10:32400', token: 'a-real-token');
      expect(checked, isTrue);
    });

    test('reports a rejection as a rejection rather than an unreachable server', () async {
      final setup = setupThat((_) async => http.Response('', 401));

      await expectLater(
        setup.checkToken(baseUrl: 'http://192.168.1.10:32400', token: 'wrong'),
        throwsA(
          isA<MediaServerAuthException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.display, 'display', 'The server did not accept that token.'),
        ),
      );
    });
  });

  group('the assembled connection', () {
    Future<void> expectBuilt(String entered, String expectedUri) async {
      final setup = setupThat((request) async {
        if (request.url.path == '/identity') return identity();
        return http.Response(
          jsonEncode({
            'MediaContainer': {'size': 0},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final connection = await setup.build(baseUrl: entered, token: 'a-real-token', clientIdentifier: 'this-device');

      // Keyed by the server's own identity, so the same server added twice --
      // at a second address, or after its token was reissued -- updates one
      // row instead of growing another.
      expect(connection.id, 'direct.bms-1');
      expect(connection.direct, isTrue);
      expect(connection.accountToken, 'a-real-token');
      expect(connection.clientIdentifier, 'this-device');
      expect(connection.accountLabel, 'The house');
      expect(connection.servers, hasLength(1));
      final server = connection.servers.single;
      expect(server.clientIdentifier, 'bms-1');
      expect(server.accessToken, 'a-real-token');
      expect(server.owned, isTrue);
      expect(server.connections.single.uri, expectedUri);
    }

    test(
      'carries the one address the user typed',
      () => expectBuilt('http://192.168.1.10:32400', 'http://192.168.1.10:32400'),
    );

    test('tolerates a trailing slash', () => expectBuilt('http://192.168.1.10:32400/', 'http://192.168.1.10:32400'));

    test('survives a round trip through its persisted form', () async {
      final setup = setupThat((request) async {
        if (request.url.path == '/identity') return identity();
        return http.Response(
          jsonEncode({
            'MediaContainer': {'size': 0},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final built = await setup.build(
        baseUrl: 'http://192.168.1.10:32400',
        token: 'a-real-token',
        clientIdentifier: 'this-device',
      );

      // The flag has to survive restart: a direct row read back as an ordinary
      // Plex account would have its token sent to plex.tv on the next bind.
      final restored = PlexAccountConnection.fromConfigJson(
        id: built.id,
        json: built.toConfigJson(),
        createdAt: built.createdAt,
        lastAuthenticatedAt: built.lastAuthenticatedAt,
      );
      expect(restored.direct, isTrue);
      expect(restored.servers.single.connections.single.uri, 'http://192.168.1.10:32400');
    });
  });

  group('what the form will accept', () {
    test('takes an address with a scheme and a port', () {
      expect(BaskServerSetup.isValidUrl('http://192.168.1.10:32400'), isTrue);
      expect(BaskServerSetup.isValidUrl('https://bask.example.com'), isTrue);
    });

    test('refuses what the candidate list could not hold', () {
      expect(BaskServerSetup.isValidUrl(''), isFalse);
      expect(BaskServerSetup.isValidUrl('not a url'), isFalse);
      expect(BaskServerSetup.isValidUrl('ftp://192.168.1.10'), isFalse);
    });
  });
}
