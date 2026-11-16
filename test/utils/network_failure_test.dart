import 'package:flutter_test/flutter_test.dart';
import 'package:bask/utils/network_failure.dart';

void main() {
  group('isNetworkFailureMessage', () {
    test('recognises the Android resolver failures downloads actually report', () {
      expect(
        isNetworkFailureMessage(
          'Unable to resolve host "100-100-1-10.abc.plex.direct": No address associated with hostname',
        ),
        isTrue,
      );
      expect(isNetworkFailureMessage('Failed host lookup: plex.example.com'), isTrue);
    });

    test('recognises transport failures', () {
      expect(isNetworkFailureMessage('Network is unreachable'), isTrue);
      expect(isNetworkFailureMessage('Connection refused'), isTrue);
      expect(isNetworkFailureMessage('Software caused connection abort'), isTrue);
      expect(isNetworkFailureMessage('Connection timed out'), isTrue);
    });

    test('a server rejecting the request is not a network failure', () {
      expect(isNetworkFailureMessage('500 Internal Server Error'), isFalse);
      expect(isNetworkFailureMessage('404 Not Found'), isFalse);
      expect(isNetworkFailureMessage('Insufficient storage'), isFalse);
    });

    test('nothing to classify', () {
      expect(isNetworkFailureMessage(null), isFalse);
      expect(isNetworkFailureMessage(''), isFalse);
    });
  });
}
