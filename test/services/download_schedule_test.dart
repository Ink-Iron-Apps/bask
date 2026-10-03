import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/download_schedule.dart';

void main() {
  group('isWithinDownloadWindow', () {
    test('a window off allows any hour', () {
      for (final hour in [0, 9, 13, 23]) {
        expect(
          isWithinDownloadWindow(enabled: false, startHour: 1, endHour: 7, now: DateTime(2026, 10, 3, hour)),
          isTrue,
        );
      }
    });

    test('a daytime window includes its start and excludes its end', () {
      bool at(int hour) =>
          isWithinDownloadWindow(enabled: true, startHour: 9, endHour: 17, now: DateTime(2026, 10, 3, hour));

      expect(at(8), isFalse);
      expect(at(9), isTrue);
      expect(at(16), isTrue);
      expect(at(17), isFalse);
    });

    test('an overnight window wraps midnight', () {
      // The useful windows are the ones that cross midnight, which a plain
      // start-before-end comparison cannot express.
      bool at(int hour) =>
          isWithinDownloadWindow(enabled: true, startHour: 22, endHour: 6, now: DateTime(2026, 10, 3, hour));

      expect(at(21), isFalse);
      expect(at(22), isTrue);
      expect(at(0), isTrue);
      expect(at(5), isTrue);
      expect(at(6), isFalse);
      expect(at(12), isFalse);
    });

    test('equal ends are read as no window, not as never', () {
      // The alternative is an app that silently never downloads.
      expect(isWithinDownloadWindow(enabled: true, startHour: 3, endHour: 3, now: DateTime(2026, 10, 3, 15)), isTrue);
    });
  });

  group('metered allowance', () {
    test('no budget is never spent', () {
      expect(isMeteredBudgetSpent(budgetMegabytes: 0, usedBytes: 99 * 1024 * 1024 * 1024), isFalse);
    });

    test('the allowance is spent at the limit, not past it', () {
      const oneGb = 1024 * 1024 * 1024;
      expect(isMeteredBudgetSpent(budgetMegabytes: 1024, usedBytes: oneGb - 1), isFalse);
      expect(isMeteredBudgetSpent(budgetMegabytes: 1024, usedBytes: oneGb), isTrue);
    });

    test('a new month resets the counter without anything running at midnight', () {
      final september = DateTime(2026, 9, 30, 23);
      final october = DateTime(2026, 10, 1, 0, 1);
      final stored = meteredUsagePeriod(september);

      expect(meteredUsageForPeriod(storedPeriod: stored, storedBytes: 5000, now: september), 5000);
      expect(meteredUsageForPeriod(storedPeriod: stored, storedBytes: 5000, now: october), 0);
    });

    test('a missing or negative counter reads as nothing used', () {
      final now = DateTime(2026, 10, 3);
      expect(meteredUsageForPeriod(storedPeriod: null, storedBytes: 900, now: now), 0);
      expect(meteredUsageForPeriod(storedPeriod: meteredUsagePeriod(now), storedBytes: -5, now: now), 0);
    });

    test('the period label is sortable and zero-padded', () {
      expect(meteredUsagePeriod(DateTime(2026, 1, 9)), '2026-01');
      expect(meteredUsagePeriod(DateTime(2026, 12, 31)), '2026-12');
    });
  });

  test('window hours read as a plain 24-hour clock', () {
    expect(formatDownloadWindowHour(0), '00:00');
    expect(formatDownloadWindowHour(7), '07:00');
    expect(formatDownloadWindowHour(22), '22:00');
  });
}
