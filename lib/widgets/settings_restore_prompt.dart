import 'package:flutter/widgets.dart';

import '../i18n/strings.g.dart';
import '../services/settings_export_service.dart';
import '../utils/dialogs.dart';
import '../utils/formatters.dart';

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
