import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/services/server_health.dart';

ServerHealth health({
  bool online = true,
  bool visible = true,
  bool authError = false,
  ServerLinkKind link = ServerLinkKind.local,
}) => ServerHealth(
  serverId: 'srv',
  name: 'Server',
  backend: MediaBackend.plex,
  online: online,
  visible: visible,
  authError: authError,
  link: link,
);

void main() {
  group('needsAttention', () {
    test('a relayed server is flagged even though it is working', () {
      // The whole point of the screen: a relayed stream is capped around
      // 2 Mbps and looks exactly like a bad connection, while the server
      // itself reads perfectly healthy.
      expect(health(link: ServerLinkKind.relay).needsAttention, isTrue);
    });

    test('a local or direct server in good standing is not flagged', () {
      expect(health(link: ServerLinkKind.local).needsAttention, isFalse);
      expect(health(link: ServerLinkKind.remote).needsAttention, isFalse);
      expect(health(link: ServerLinkKind.unknown).needsAttention, isFalse);
    });

    test('a rejected sign-in is flagged however the link looks', () {
      expect(health(authError: true).needsAttention, isTrue);
    });

    test('a visible server that is not answering is flagged', () {
      expect(health(online: false).needsAttention, isTrue);
    });

    test('a server hidden from this profile is a choice, not a fault', () {
      // Hiding a borrowed server is something the user did; drawing a warning
      // on it would make the screen cry wolf.
      expect(health(online: false, visible: false).needsAttention, isFalse);
    });
  });

  group('redactEndpoint', () {
    test('leaves an ordinary endpoint alone', () {
      expect(
        redactEndpoint('https://192-168-1-20.abc.plex.direct:32400'),
        'https://192-168-1-20.abc.plex.direct:32400',
      );
    });

    test('strips a query string, which can carry a token', () {
      // This is a screen people photograph to ask for help with.
      expect(redactEndpoint('https://media.example.com/?X-Plex-Token=secret'), 'https://media.example.com/');
    });

    test('strips credentials embedded in the authority', () {
      expect(redactEndpoint('http://user:pass@10.0.0.5:8096'), 'http://10.0.0.5:8096');
    });

    test('passes through nothing at all', () {
      expect(redactEndpoint(null), isNull);
      expect(redactEndpoint(''), isNull);
    });
  });
}
