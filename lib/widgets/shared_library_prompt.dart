import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../providers/download_provider.dart';
import '../i18n/strings.g.dart';
import '../services/shared_library_adoption.dart';
import '../services/shared_storage_service.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';
import 'settings_restore_prompt.dart';

/// Explains what shared-storage access is for, then sends the viewer to the
/// screen that grants it.
///
/// Android has no dialog for `MANAGE_EXTERNAL_STORAGE`: an app can only open
/// the Settings page and look again afterwards. Dropping someone onto that
/// page with no warning reads like a bug, so the reason comes first. It also
/// has to come first in the other sense — the folder is unreadable until the
/// permission is held, so the app cannot say what it found before asking.
Future<bool> promptForSharedStorageAccess(BuildContext context) {
  return showConfirmDialog(
    context,
    title: t.settings.adoptLibraryPermissionTitle,
    message: t.settings.adoptLibraryPermissionMessage,
    confirmText: t.settings.adoptLibraryPermissionConfirm,
    cancelText: t.settings.restoreBackupDecline,
  );
}

/// Offers the library found in shared storage, naming its size and where it
/// is.
///
/// The folder is in the message because it is the one thing the viewer cannot
/// guess, and the thing they can go and look at if the count surprises them.
Future<bool> promptToAdoptLibrary(BuildContext context, SharedLibraryDescriptor descriptor) {
  return showConfirmDialog(
    context,
    title: t.settings.adoptLibraryFoundTitle,
    message: t.settings.adoptLibraryFoundMessage(
      count: descriptor.fileCount,
      location: descriptor.downloadsPath,
    ),
    confirmText: t.settings.adoptLibraryConfirm,
    cancelText: t.settings.adoptLibraryDecline,
  );
}

/// Runs an adoption behind a spinner.
///
/// No progress bar and no Stop button, because nothing is copied: the folder
/// becomes the download root where it already lies, so the work is a settings
/// import and a few hundred rows however many gigabytes the folder holds.
Future<SharedLibraryAdoptionResult?> runLibraryAdoption(
  BuildContext context, {
  required SharedLibraryAdoptionService service,
  required SharedLibraryDescriptor descriptor,
  required AppDatabase database,
  Future<String?> Function()? passphraseProvider,
}) async {
  final dialog = ScopedLoadingDialogController();
  dialog.show(
    context,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(t.settings.adoptLibraryProgressTitle),
        content: const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
      ),
    ),
  );

  try {
    return await service.adopt(
      descriptor: descriptor,
      database: database,
      passphraseProvider: passphraseProvider,
    );
  } catch (error, stackTrace) {
    appLogger.w('Could not adopt the shared library', error: error, stackTrace: stackTrace);
    return null;
  } finally {
    await dialog.dismiss();
  }
}

/// The adoption end to end: the permission, what is in the folder, the
/// question, the work behind its spinner, and what happened.
///
/// One function because there are two callers and the reporting is the same
/// for both — Settings, where the viewer asked for this, and startup, where
/// the app asks once on a fresh install. [announceNothing] separates them: a
/// viewer who pressed the button is owed an answer when there turns out to be
/// nothing in the folder, and startup should say nothing at all in that case.
///
/// Returns the result, or null when there was nothing to adopt, the offer was
/// declined, or the context went away.
///
/// The downloads provider is read from [context] unless a [service] was
/// injected, which is what a test does: it supplies the whole adoption and has
/// no provider above the host widget.
Future<SharedLibraryAdoptionResult?> offerSharedLibraryAdoption(
  BuildContext context, {
  required AppDatabase database,
  SharedLibraryAdoptionService? service,
  SharedStorageService? storage,
  bool announceNothing = false,
  VoidCallback? onPermissionPending,
}) async {
  final downloads = service == null ? context.read<DownloadProvider>() : null;
  final library =
      service ??
      SharedLibraryAdoptionService(
        setDownloadLocation: (path, pathType) =>
            downloads!.setDownloadLocation(path: path, pathType: pathType),
      );
  final shared = storage ?? SharedStorageService.instance;

  if (!await library.isAvailable || !await shared.canRequestAccess()) {
    if (context.mounted && announceNothing) showSnackBar(context, t.settings.adoptLibraryUnsupported);
    return null;
  }
  if (!context.mounted) return null;

  if (!await shared.hasAccess()) {
    if (!context.mounted) return null;
    if (!await promptForSharedStorageAccess(context)) return null;
    await shared.requestAccess();
    // The grant happens on another screen, so there is nothing to await. Look
    // again when the viewer comes back and asks a second time, rather than
    // polling or guessing when they are done.
    if (!await shared.hasAccess()) {
      // They said yes and went to grant it, so the question is worth putting
      // again — most people come back to the app rather than to this offer,
      // and by the next launch the permission is held and the folder can
      // simply be described. A decline does not land here and stays spent.
      onPermissionPending?.call();
      if (context.mounted) showSnackBar(context, t.settings.adoptLibraryPermissionMissing);
      return null;
    }
  }
  if (!context.mounted) return null;

  final SharedLibraryDescriptor? descriptor;
  try {
    descriptor = await library.descriptor();
  } catch (error, stackTrace) {
    appLogger.w('Could not read the shared library folder', error: error, stackTrace: stackTrace);
    return null;
  }
  if (!context.mounted) return null;

  if (descriptor == null) {
    if (announceNothing) showSnackBar(context, t.settings.adoptLibraryNothing);
    return null;
  }
  if (library.isAlreadyAdopted(descriptor)) {
    if (announceNothing) showSnackBar(context, t.settings.adoptLibraryAlready);
    return null;
  }

  if (!await promptToAdoptLibrary(context, descriptor) || !context.mounted) return null;

  Future<String?> askPassphrase() => context.mounted ? promptForCredentialPassphrase(context) : Future.value();
  final result = await runLibraryAdoption(
    context,
    service: library,
    descriptor: descriptor,
    database: database,
    passphraseProvider: askPassphrase,
  );
  if (result == null) return null;

  // Reloads the list and claims the imported records for the active profile,
  // which is what makes them visible: they arrive ownerless on purpose. Done
  // before reporting, so the snackbar and the library agree.
  if (result.rowsImported > 0) {
    try {
      await downloads?.refresh();
    } catch (error, stackTrace) {
      appLogger.w('Could not reload downloads after adopting a library', error: error, stackTrace: stackTrace);
    }
  }
  if (!context.mounted) return result;

  if (!result.adoptedRoot) {
    showErrorSnackBar(context, t.settings.adoptLibraryFailed);
  } else if (result.filesClaimed == 0 && result.filesOnDisk > 0) {
    // The media is where the app looks for it and new downloads will join it,
    // but nothing describes what is already there, so the library still looks
    // empty. Said plainly rather than reported as a success.
    showErrorSnackBar(context, t.settings.adoptLibraryNoRecords(count: result.filesOnDisk));
  } else if (result.filesUnclaimed > 0) {
    showSnackBar(
      context,
      t.settings.adoptLibraryPartial(done: result.filesClaimed, total: result.filesOnDisk),
    );
  } else {
    showSuccessSnackBar(context, t.settings.adoptLibraryDone(count: result.filesClaimed));
  }
  return result;
}
