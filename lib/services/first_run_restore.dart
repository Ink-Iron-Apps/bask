import '../utils/app_logger.dart';
import 'settings_export_service.dart';
import 'settings_service.dart';
import 'storage_service.dart';

/// Decides whether a fresh install should be offered the settings backup it
/// found sitting next to it.
///
/// A file can be there without anyone having put it there deliberately:
/// Android's own app backup restores the documents directory, an adb copy
/// lands one, and the signature-protected handoff will write one across a
/// rename. None of those announce themselves, so the app looks.
///
/// Three conditions, each closing a way this could go wrong:
///
/// * **Asked once, ever.** [SettingsService.restorePromptShown] is set the
///   moment the question is put, answered either way. Nobody gets nagged on
///   every launch by a file they have decided to ignore.
/// * **Only on an install with nothing to lose.** A year-old install with its
///   own settings must never be offered a restore over them; the offer is for
///   an install that has not been configured yet.
/// * **Never a backup from this session.** The automatic backup writes on
///   startup when none exists, so on a fresh install the newest file on disk
///   is a snapshot of the empty settings taken seconds ago. Offering to
///   restore that would be a loop with no content in it.
class FirstRunRestore {
  FirstRunRestore._();

  /// The backup worth offering, or null when there is nothing to offer.
  ///
  /// [sessionStart] is when this process began; files newer than it were
  /// written by this run and are not candidates.
  static Future<LocalExportFile?> candidate({
    required SettingsService settings,
    required StorageService storage,
    required DateTime sessionStart,
  }) async {
    if (!isEligible(settings: settings, storage: storage)) return null;
    return localBackup(sessionStart: sessionStart);
  }

  /// Whether this install is in a position to be offered anything at all.
  ///
  /// Separate from finding a source, because the sources differ in where they
  /// come from and one of them — the handoff from a predecessor app — exists
  /// precisely when there is no local file to find.
  static bool isEligible({required SettingsService settings, required StorageService storage}) {
    if (settings.read(SettingsService.restorePromptShown)) return false;

    // An import re-scopes user-scoped keys onto the signed-in account, and
    // throws without one. On a genuinely fresh install nobody is signed in
    // until setup finishes, so the offer waits for that rather than failing.
    final scope = storage.activeUserScope();
    if (scope == null || scope.isEmpty) return false;

    return isUnconfigured(settings);
  }

  /// The newest backup on this device written before this session, or null.
  static Future<LocalExportFile?> localBackup({required DateTime sessionStart}) async {
    final exports = await SettingsExportService.listLocalExports();
    for (final export in exports) {
      if (export.modified.isBefore(sessionStart)) return export;
    }
    return null;
  }

  /// Whether this install still looks untouched.
  ///
  /// Read against the portable registry rather than the whole store: an
  /// install that has signed in and nothing more has written plenty of
  /// internal keys, and none of them mean the viewer has configured
  /// anything.
  static bool isUnconfigured(SettingsService settings) {
    for (final pref in SettingsService.portablePrefs) {
      if (settings.prefs.containsKey(pref.key)) return false;
    }
    return true;
  }

  /// Records that the question has been put, so it is never put again.
  static Future<void> markOffered(SettingsService settings) async {
    try {
      await settings.write(SettingsService.restorePromptShown, true);
    } catch (error, stackTrace) {
      // Failing to record it would mean asking again next launch, which is
      // irritating but not harmful, so it is logged rather than surfaced.
      appLogger.w('Could not record the first-run restore prompt', error: error, stackTrace: stackTrace);
    }
  }
}
