import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item_labels.dart';
import 'package:plezy/media/media_kind.dart';

import '../test_helpers/media_items.dart';

void main() {
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  test('an episode keeps the episode wording', () {
    final episode = testMediaItem(id: 'e1', kind: MediaKind.episode);
    expect(nextItemLabel(episode, compact: false), 'Next Episode');
    expect(nextItemLabel(episode, compact: true), 'Next episode');
  });

  test('a movie does not claim to be an episode', () {
    // Anchor: a downloaded playlist of films is a real queue in this fork, and
    // "Next episode" on it is simply wrong.
    final movie = testMediaItem(id: 'm1', kind: MediaKind.movie);
    expect(nextItemLabel(movie, compact: false), 'Next Video');
    expect(nextItemLabel(movie, compact: true), 'Next video');
  });

  test('an unknown next item reads as an episode, the older behaviour', () {
    expect(nextItemLabel(null, compact: false), 'Next Episode');
  });
}
