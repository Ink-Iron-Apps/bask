/// Why downloads are not starting right now, when nothing is wrong.
enum DownloadHoldReason {
  /// Outside the hours the user allowed.
  outsideWindow,

  /// The month's allowance of metered data is spent.
  meteredBudgetSpent,
}

/// Whether [now] falls inside the allowed download window.
///
/// A window exists because an unattended queue is otherwise unattended all
/// day: a sync rule that fills itself at noon competes with everything else
/// the connection is doing, and on a shared line that is felt by other people.
/// Overnight is the obvious answer and the hardest to express as a plain
/// "start before end", because the useful windows wrap midnight.
///
/// Hours are local and inclusive of [startHour], exclusive of [endHour], so
/// 1 to 7 means 01:00 until 06:59. A window whose ends are equal is treated as
/// no window at all rather than as a single instant: the alternative is an app
/// that silently never downloads.
bool isWithinDownloadWindow({
  required bool enabled,
  required int startHour,
  required int endHour,
  required DateTime now,
}) {
  if (!enabled) return true;
  if (startHour == endHour) return true;

  final hour = now.hour;
  if (startHour < endHour) return hour >= startHour && hour < endHour;
  // Wraps midnight: 22 to 6 is late evening plus early morning.
  return hour >= startHour || hour < endHour;
}

/// Whether the month's metered allowance is used up.
///
/// [budgetMegabytes] of 0 means no limit. The budget is deliberately about
/// metered bytes only: downloads over WiFi are not what runs a bill up.
bool isMeteredBudgetSpent({required int budgetMegabytes, required int usedBytes}) {
  if (budgetMegabytes <= 0) return false;
  return usedBytes >= budgetMegabytes * 1024 * 1024;
}

/// The calendar month a usage counter belongs to, as `yyyy-mm`.
///
/// Stored alongside the counter so a new month resets it without needing a
/// scheduled job: whoever reads it next notices the label changed.
String meteredUsagePeriod(DateTime now) =>
    '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';

/// Bytes counted so far in the period [now] belongs to.
///
/// Returns 0 when [storedPeriod] names a different month, which is the reset.
int meteredUsageForPeriod({required String? storedPeriod, required int storedBytes, required DateTime now}) {
  if (storedPeriod != meteredUsagePeriod(now)) return 0;
  return storedBytes < 0 ? 0 : storedBytes;
}

/// An hour of the day as the window controls show it.
///
/// Plain 24-hour-clock text: the window is a pair of hours, and a localized
/// time format for something with no minutes reads as more precision than
/// there is.
String formatDownloadWindowHour(int hour) => '${hour.toString().padLeft(2, '0')}:00';
