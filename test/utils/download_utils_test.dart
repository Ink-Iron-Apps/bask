import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/utils/download_utils.dart';

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  test('episode count validation returns a localized message for invalid input', () {
    expect(validateEpisodeCountInput('', allowZero: false), t.downloads.invalidEpisodeCount);
    expect(validateEpisodeCountInput('0', allowZero: false), t.downloads.invalidEpisodeCount);
    expect(validateEpisodeCountInput('not-a-number', allowZero: true), t.downloads.invalidEpisodeCount);
  });

  test('episode count validation accepts zero only when requested', () {
    expect(validateEpisodeCountInput('0', allowZero: true), isNull);
    expect(validateEpisodeCountInput('12', allowZero: false), isNull);
  });

  group('syncRuleCountFor', () {
    test('an unwatched rule keeps a window rather than the whole show', () {
      // The bug: picking "Unwatched" with Keep synced stored 0, which the
      // executor reads as every matching episode, so a show with four
      // unwatched seasons downloaded four seasons.
      expect(syncRuleCountFor(filter: DownloadFilter.unwatched), defaultUnwatchedSyncCount);
      expect(defaultUnwatchedSyncCount, greaterThan(0));
    });

    test('download-all still mirrors the show, including later episodes', () {
      expect(syncRuleCountFor(filter: DownloadFilter.all), 0);
    });

    test('a chosen count wins over either default', () {
      expect(syncRuleCountFor(filter: DownloadFilter.unwatched, explicitCount: 5), 5);
      expect(syncRuleCountFor(filter: DownloadFilter.all, explicitCount: 3), 3);
      // Zero stays meaningful: it is how "no cap" is stored.
      expect(syncRuleCountFor(filter: DownloadFilter.unwatched, explicitCount: 0), 0);
    });
  });
}
