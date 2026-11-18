import 'package:flutter/material.dart';

import '../database/app_database.dart';
import '../i18n/strings.g.dart';
import '../services/download_handoff_service.dart';
import '../services/settings_export_service.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/formatters.dart';
import '../utils/snackbar_helper.dart';

/// The passphrase that opens a credential section, asked for in the one place
/// both callers can reach it: Settings' own import, and the first-run restore.
///
/// Obscured, and never defaulted or remembered — an export's passphrase is
/// the only thing standing between the file and the account it signs into,
/// so the app does not keep a copy.
Future<String?> promptForCredentialPassphrase(BuildContext context) {
  return showTextInputDialog(
    context,
    title: t.settings.credentialPassphraseImportTitle,
    labelText: t.settings.credentialPassphraseImportLabel,
    obscureText: true,
  );
}

/// Offers the settings a previous install of the app is still holding.
///
/// Worded as a handoff rather than a restore because that is what it is: the
/// old app is still on the device, and nothing is being recovered from a
/// file. Sign-ins deliberately do not travel this way — the handoff carries
/// the automatic, settings-only backup, which no passphrase protects.
Future<bool> promptToAcceptHandoff(BuildContext context) {
  return showConfirmDialog(
    context,
    title: t.settings.restoreHandoffFoundTitle,
    message: t.settings.restoreHandoffFoundMessage,
    confirmText: t.settings.restoreBackupConfirm,
    cancelText: t.settings.restoreBackupDecline,
  );
}

/// Offers a backup found on this device, naming when it was taken.
///
/// The date is the whole decision: a backup from this morning is obviously
/// worth restoring, and one from two years ago obviously needs thinking
/// about. Returns whether the viewer accepted.
Future<bool> promptToRestoreBackup(BuildContext context, LocalExportFile backup) {
  return showConfirmDialog(
    context,
    title: t.settings.restoreBackupFoundTitle,
    message: t.settings.restoreBackupFoundMessage(when: formatAbbreviatedDate(backup.modified.toIso8601String())),
    confirmText: t.settings.restoreBackupConfirm,
    cancelText: t.settings.restoreBackupDecline,
  );
}

/// Offers the downloaded media a previous install is still holding.
///
/// The size is the whole decision — a viewer with forty gigabytes of
/// downloads needs to know that before saying yes, and one with two episodes
/// does not need to think about it. States plainly that this copies rather
/// than moves, because the reassuring part is that saying yes cannot lose
/// anything.
Future<bool> promptToBringDownloads(BuildContext context, DownloadHandoffManifest manifest) {
  return showConfirmDialog(
    context,
    title: t.settings.restoreDownloadsFoundTitle,
    message: t.settings.restoreDownloadsFoundMessage(
      count: manifest.entries.length,
      size: ByteFormatter.formatBytes(manifest.totalBytes),
    ),
    confirmText: t.settings.restoreDownloadsConfirm,
    cancelText: t.settings.restoreDownloadsDecline,
  );
}

/// Runs a download handoff behind a progress dialog that can be stopped.
///
/// Not dismissible by tapping away: a copy measured in gigabytes should not be
/// abandoned by a stray tap, so stopping is a deliberate button. Stopping is
/// safe at any point — whole files already copied are kept and a later run
/// resumes from there — which is why the button says Stop rather than Cancel.
Future<DownloadHandoffResult?> runDownloadHandoff(
  BuildContext context, {
  required DownloadHandoffService service,
  required DownloadHandoffManifest manifest,
  required AppDatabase database,
}) async {
  final progress = ValueNotifier<DownloadHandoffProgress>(
    DownloadHandoffProgress(
      filesCopied: 0,
      filesTotal: manifest.entries.length,
      bytesCopied: 0,
      bytesTotal: manifest.fileBytes,
    ),
  );
  var stopped = false;

  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: Text(t.settings.restoreDownloadsProgressTitle),
      content: ValueListenableBuilder<DownloadHandoffProgress>(
        valueListenable: progress,
        builder: (_, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: value.fraction),
            const SizedBox(height: 12),
            Text(
              t.settings.restoreDownloadsProgressDetail(
                done: value.filesCopied,
                total: value.filesTotal,
                size: ByteFormatter.formatBytes(value.bytesCopied),
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => stopped = true, child: Text(t.settings.restoreDownloadsStop))],
    ),
  );

  // `showDialog` pushes onto the root navigator, so the dismissal has to
  // target that same navigator. A tablet layout nests a navigator per tab and
  // `Navigator.of(context)` finds the nested one: popping that leaves the
  // dialog standing with no way out, because the Stop button only asks the
  // copy to cancel and never pops. Resolved before the copy starts so
  // dismissing does not depend on `context` still being mounted once it
  // finishes — a check that could otherwise skip the dismissal silently.
  final navigator = Navigator.of(context, rootNavigator: true);

  try {
    return await service.restore(
      manifest: manifest,
      database: database,
      onProgress: (value) => progress.value = value,
      isCancelled: () => stopped,
    );
  } finally {
    navigator.pop();
    await dialog;
    progress.dispose();
  }
}

/// The download handoff end to end: what the previous install is holding, the
/// question, the copy behind its progress dialog, and what happened.
///
/// One function because there are two callers and the reporting is the same
/// for both — Settings, where the viewer asked for this, and startup, where
/// the app asks after a rename. [announceNothing] separates them: a viewer
/// who pressed the button is owed an answer when the predecessor turns out to
/// have nothing, and startup should say nothing at all in that case.
///
/// Returns the result, or null when there was nothing to offer, the offer was
/// declined, or the context went away.
Future<DownloadHandoffResult?> offerDownloadHandoff(
  BuildContext context, {
  required AppDatabase database,
  DownloadHandoffService? service,
  bool announceNothing = false,
}) async {
  final handoff = service ?? DownloadHandoffService();
  final DownloadHandoffManifest? manifest;
  try {
    manifest = await handoff.manifest();
  } catch (error, stackTrace) {
    appLogger.w("Could not read the previous install's downloads", error: error, stackTrace: stackTrace);
    return null;
  }
  if (!context.mounted) return null;
  if (manifest == null || manifest.isEmpty) {
    if (announceNothing) showSnackBar(context, t.settings.restoreDownloadsNothing);
    return null;
  }

  if (!await promptToBringDownloads(context, manifest) || !context.mounted) return null;

  final result = await runDownloadHandoff(context, service: handoff, manifest: manifest, database: database);
  if (result == null || !context.mounted) return result;

  if (result.cancelled) {
    showSnackBar(context, t.settings.restoreDownloadsStopped);
  } else if (result.filesFailed > 0) {
    showErrorSnackBar(
      context,
      t.settings.restoreDownloadsPartial(
        done: result.filesCopied + result.filesSkipped,
        total: manifest.entries.length,
      ),
    );
  } else {
    showSuccessSnackBar(context, t.settings.restoreDownloadsDone(count: result.rowsImported));
  }
  return result;
}
