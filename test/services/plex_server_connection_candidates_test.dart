import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/plex_auth_service.dart';

Map<String, dynamic> _serverJson(Map<String, dynamic> connection) => _serverJsonWithConnections([connection]);

Map<String, dynamic> _serverJsonWithConnections(List<Map<String, dynamic>> connections) => {
  'name': 'Home Server',
  'clientIdentifier': 'srv-1',
  'accessToken': 'token-1',
  'owned': true,
  'connections': connections,
};

Map<String, dynamic> _connectionJson({
  required String protocol,
  required String address,
  required int port,
  required String uri,
  bool local = false,
  bool relay = false,
}) => {'protocol': protocol, 'address': address, 'port': port, 'uri': uri, 'local': local, 'relay': relay};

void main() {
  group('PlexServer connection candidates', () {
    test('adds a user-supplied endpoint plex.tv never advertised', () {
      // plex.tv only advertises endpoints it can reach from the internet, so a
      // tailnet address is never in the list no matter what the server is
      // configured to publish. The user pins it by hand instead.
      final server = PlexServer.fromJson(
        _serverJson(
          _connectionJson(
            protocol: 'http',
            address: '10.71.1.209',
            port: 32400,
            uri: 'http://10.71.1.209:32400',
            local: true,
          ),
        ),
      ).withCustomEndpoints(const ['http://100.100.1.10:32400']);

      final urls = server.prioritizedEndpointUrls();

      expect(urls, contains('http://100.100.1.10:32400'));
      // Still behind the LAN address: on Wi-Fi the direct route wins.
      expect(urls.indexOf('http://10.71.1.209:32400'), lessThan(urls.indexOf('http://100.100.1.10:32400')));
    });

    test('keeps a user-supplied tailnet endpoint through remote failover', () {
      final server = PlexServer.fromJson(
        _serverJsonWithConnections([
          _connectionJson(
            protocol: 'http',
            address: '10.71.1.209',
            port: 32400,
            uri: 'http://10.71.1.209:32400',
            local: true,
          ),
          _connectionJson(protocol: 'https', address: 'plex.example.com', port: 443, uri: 'https://plex.example.com'),
        ]),
      ).withCustomEndpoints(const ['http://100.100.1.10:32400']);

      final urls = server.prioritizedEndpointUrls(preferredFirst: 'https://plex.example.com');

      expect(urls, contains('http://100.100.1.10:32400'));
      expect(urls, isNot(contains('http://10.71.1.209:32400')));
    });

    test('a custom MagicDNS endpoint is treated as tailnet-local', () {
      final server = PlexServer.fromJson(
        _serverJson(
          _connectionJson(
            protocol: 'http',
            address: '10.71.1.209',
            port: 32400,
            uri: 'http://10.71.1.209:32400',
            local: true,
          ),
        ),
      ).withCustomEndpoints(const ['http://desktop.tail66425b.ts.net:32400']);

      expect(server.networkClassForUrl('http://desktop.tail66425b.ts.net:32400'), PlexNetworkClass.local);
    });

    test('ignores blank and unparseable custom endpoints', () {
      final base = _serverJson(
        _connectionJson(
          protocol: 'http',
          address: '10.71.1.209',
          port: 32400,
          uri: 'http://10.71.1.209:32400',
          local: true,
        ),
      );
      final server = PlexServer.fromJson(base).withCustomEndpoints(const ['', '   ', 'not a url', 'ftp://x:1']);

      expect(server.prioritizedEndpointUrls(), ['http://10.71.1.209:32400']);
    });

    test('does not duplicate a custom endpoint plex.tv already advertises', () {
      final server = PlexServer.fromJson(
        _serverJson(
          _connectionJson(
            protocol: 'http',
            address: '10.71.1.209',
            port: 32400,
            uri: 'http://10.71.1.209:32400',
            local: true,
          ),
        ),
      ).withCustomEndpoints(const ['http://10.71.1.209:32400']);

      expect(server.prioritizedEndpointUrls().where((u) => u == 'http://10.71.1.209:32400'), hasLength(1));
    });

    test('prefers the LAN address over a tailnet address', () {
      // Both are advertised local. On Wi-Fi the LAN address is the direct route;
      // the tailnet address goes through the VPN even when the server is a hop
      // away, so it must not win the ordering.
      final server = PlexServer.fromJson(
        _serverJsonWithConnections([
          _connectionJson(
            protocol: 'http',
            address: '100.101.102.103',
            port: 32400,
            uri: 'http://100.101.102.103:32400',
            local: true,
          ),
          _connectionJson(
            protocol: 'http',
            address: '192.168.1.50',
            port: 32400,
            uri: 'http://192.168.1.50:32400',
            local: true,
          ),
        ]),
      );

      final urls = server.prioritizedEndpointUrls();

      expect(urls.indexOf('http://192.168.1.50:32400'), lessThan(urls.indexOf('http://100.101.102.103:32400')));
    });

    test('keeps a tailnet address in the chain when failing over from a remote endpoint', () {
      // A LAN address is unreachable once the client is off-LAN, which is why
      // local candidates are culled during remote failover (#902). A tailnet
      // address is reachable from anywhere the VPN is up, so it must survive.
      final server = PlexServer.fromJson(
        _serverJsonWithConnections([
          _connectionJson(
            protocol: 'http',
            address: '192.168.1.50',
            port: 32400,
            uri: 'http://192.168.1.50:32400',
            local: true,
          ),
          _connectionJson(
            protocol: 'http',
            address: '100.101.102.103',
            port: 32400,
            uri: 'http://100.101.102.103:32400',
            local: true,
          ),
          _connectionJson(protocol: 'https', address: 'plex.example.com', port: 443, uri: 'https://plex.example.com'),
        ]),
      );

      final urls = server.prioritizedEndpointUrls(preferredFirst: 'https://plex.example.com');

      expect(urls, contains('http://100.101.102.103:32400'));
      expect(urls, isNot(contains('http://192.168.1.50:32400')));
    });

    test('classifies a tailnet address as local', () {
      final server = PlexServer.fromJson(
        _serverJson(
          _connectionJson(
            protocol: 'http',
            address: '100.101.102.103',
            port: 32400,
            uri: 'http://100.101.102.103:32400',
            local: true,
          ),
        ),
      );

      expect(server.networkClassForUrl('http://100.101.102.103:32400'), PlexNetworkClass.local);
    });

    test('adds HTTP fallback for custom native Plex hostname on port 32400', () {
      final server = PlexServer.fromJson(
        _serverJson(
          _connectionJson(
            protocol: 'https',
            address: 'whereyaat.duckdns.org',
            port: 32400,
            uri: 'https://whereyaat.duckdns.org:32400',
          ),
        ),
      );

      final urls = server.prioritizedEndpointUrls();

      expect(server.connections.map((c) => c.uri), contains('http://whereyaat.duckdns.org:32400'));
      expect(urls, contains('https://whereyaat.duckdns.org:32400'));
      expect(urls, contains('http://whereyaat.duckdns.org:32400'));
      expect(
        urls.indexOf('https://whereyaat.duckdns.org:32400'),
        lessThan(urls.indexOf('http://whereyaat.duckdns.org:32400')),
      );
    });

    test('recognizes cached HTTP fallback for custom native Plex hostname', () {
      final server = PlexServer.fromJson(
        _serverJson(
          _connectionJson(
            protocol: 'https',
            address: 'whereyaat.duckdns.org',
            port: 32400,
            uri: 'https://whereyaat.duckdns.org:32400',
          ),
        ),
      );

      final urls = server.prioritizedEndpointUrls(preferredFirst: 'http://whereyaat.duckdns.org:32400');

      expect(server.networkClassForUrl('http://whereyaat.duckdns.org:32400'), PlexNetworkClass.remote);
      expect(urls.first, 'http://whereyaat.duckdns.org:32400');
      expect(urls.where((u) => u == 'http://whereyaat.duckdns.org:32400'), hasLength(1));
    });

    test('does not add HTTP fallback for standard HTTPS reverse proxy hostname', () {
      final server = PlexServer.fromJson(
        _serverJson(
          _connectionJson(protocol: 'https', address: 'plex.example.com', port: 443, uri: 'https://plex.example.com'),
        ),
      );

      final urls = server.prioritizedEndpointUrls();

      expect(server.connections.map((c) => c.uri), isNot(contains('http://plex.example.com')));
      expect(urls, contains('https://plex.example.com'));
      expect(urls, isNot(contains('http://plex.example.com:443')));
    });

    test('does not add HTTP fallback for path-based HTTPS hostname', () {
      final server = PlexServer.fromJson(
        _serverJson(
          _connectionJson(
            protocol: 'https',
            address: 'plex.example.com',
            port: 32400,
            uri: 'https://plex.example.com:32400/plex',
          ),
        ),
      );

      final urls = server.prioritizedEndpointUrls();

      expect(server.connections.map((c) => c.uri), isNot(contains('http://plex.example.com:32400/plex')));
      expect(urls, contains('https://plex.example.com:32400/plex'));
      expect(urls, isNot(contains('http://plex.example.com:32400')));
    });

    test('does not add HTTP fallback when native port is not in the URI', () {
      final server = PlexServer.fromJson(
        _serverJson(
          _connectionJson(protocol: 'https', address: 'plex.example.com', port: 32400, uri: 'https://plex.example.com'),
        ),
      );

      final urls = server.prioritizedEndpointUrls();

      expect(server.connections.map((c) => c.uri), isNot(contains('http://plex.example.com')));
      expect(urls, contains('https://plex.example.com'));
      expect(urls, isNot(contains('http://plex.example.com:32400')));
    });

    test('treats custom public HTTPS preferred endpoint as remote for failover filtering', () {
      const preferred = 'https://plex.example.com';
      const localPlexDirect = 'https://192-168-1-50.abc.plex.direct:32400';
      const remotePlexDirect = 'https://203-0-113-10.abc.plex.direct:32400';
      final server = PlexServer.fromJson(
        _serverJsonWithConnections([
          _connectionJson(protocol: 'https', address: '192.168.1.50', port: 32400, uri: localPlexDirect, local: true),
          _connectionJson(protocol: 'https', address: '203.0.113.10', port: 32400, uri: remotePlexDirect),
        ]),
      );

      final urls = server.prioritizedEndpointUrls(preferredFirst: preferred);

      expect(server.networkClassForUrl(preferred), PlexNetworkClass.remote);
      expect(urls.first, preferred);
      expect(urls, contains(remotePlexDirect));
      expect(urls, isNot(contains(localPlexDirect)));
      expect(urls, isNot(contains('http://192.168.1.50:32400')));
    });

    test('does not treat custom local-looking preferred endpoint as remote', () {
      const preferred = 'https://plex.lan';
      const localPlexDirect = 'https://192-168-1-50.abc.plex.direct:32400';
      final server = PlexServer.fromJson(
        _serverJsonWithConnections([
          _connectionJson(protocol: 'https', address: '192.168.1.50', port: 32400, uri: localPlexDirect, local: true),
        ]),
      );

      final urls = server.prioritizedEndpointUrls(preferredFirst: preferred);

      expect(server.networkClassForUrl(preferred), PlexNetworkClass.unknown);
      expect(urls.first, preferred);
      expect(urls, contains(localPlexDirect));
    });

    test('does not treat Tailscale CGNAT preferred endpoint as remote', () {
      const preferred = 'https://100.90.80.70:32400';
      const localPlexDirect = 'https://192-168-1-50.abc.plex.direct:32400';
      final server = PlexServer.fromJson(
        _serverJsonWithConnections([
          _connectionJson(protocol: 'https', address: '192.168.1.50', port: 32400, uri: localPlexDirect, local: true),
        ]),
      );

      final urls = server.prioritizedEndpointUrls(preferredFirst: preferred);

      expect(server.networkClassForUrl(preferred), PlexNetworkClass.unknown);
      expect(urls.first, preferred);
      expect(urls, contains(localPlexDirect));
    });

    test('does not treat Tailscale MagicDNS preferred endpoint as remote', () {
      const preferred = 'https://plex.tailnet.ts.net:32400';
      const localPlexDirect = 'https://192-168-1-50.abc.plex.direct:32400';
      final server = PlexServer.fromJson(
        _serverJsonWithConnections([
          _connectionJson(protocol: 'https', address: '192.168.1.50', port: 32400, uri: localPlexDirect, local: true),
        ]),
      );

      final urls = server.prioritizedEndpointUrls(preferredFirst: preferred);

      expect(server.networkClassForUrl(preferred), PlexNetworkClass.unknown);
      expect(urls.first, preferred);
      expect(urls, contains(localPlexDirect));
    });
  });
}
