package com.inknironapps.bask.handoff

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Process
import java.io.File

/**
 * Hands this install's settings to a successor app signed with the same key.
 *
 * Renaming an Android app changes its applicationId, which makes it a
 * different app with a different sandbox: the new install cannot read the old
 * one's files, and there is no upgrade path between them. This provider is the
 * bridge. The renamed app queries it once on first run and gets the settings
 * the viewer spent years arranging, with no file to find and nothing to copy.
 *
 * Two deliberate limits on what it will hand over:
 *
 *  * **Same signing key only.** The provider is exported, because the caller
 *    is a different app, so every call checks the caller's signature against
 *    this app's. A custom signature-level permission would do the same job,
 *    but two installed apps declaring one permission name is an install
 *    conflict waiting to happen; asking PackageManager directly has no such
 *    failure mode.
 *  * **Automatic backups only.** It serves the files
 *    `SettingsExportService.writeAutomaticBackup` writes, which are settings
 *    with no credential section, and never a manual export, which may carry
 *    passphrase-encrypted sign-ins. A handoff the viewer did not type a
 *    passphrase for must not move credentials, so it cannot be allowed to
 *    pick up a file that holds them.
 */
class SettingsHandoffProvider : ContentProvider() {

  companion object {
    /** Matches `SettingsExportService.automaticFilePrefix`. */
    private const val AUTOMATIC_PREFIX = "bask-settings-auto-"

    /** The `call` method a successor invokes. */
    const val METHOD_READ_SETTINGS = "readSettingsExport"

    /** Bundle key holding the export JSON, absent when there is none. */
    const val KEY_PAYLOAD = "payload"

    /** Bundle key holding when that export was written, epoch milliseconds. */
    const val KEY_WRITTEN_AT = "writtenAt"

    /**
     * The same directory `path_provider` hands Dart for
     * `getApplicationDocumentsDirectory()`: Flutter's own
     * `PathUtils.getDataDirectory` is `getDir("flutter", MODE_PRIVATE)`.
     * Calling it the same way rather than rebuilding the path keeps the two
     * sides in agreement by construction.
     */
    private fun documentsDir(context: Context): File = context.getDir("flutter", Context.MODE_PRIVATE)
  }

  override fun onCreate(): Boolean = true

  override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
    val context = context ?: return null
    if (!callerSharesOurSignature(context)) {
      throw SecurityException("Settings handoff is limited to apps signed with the same key")
    }
    if (method != METHOD_READ_SETTINGS) return null

    val newest = newestAutomaticBackup(context) ?: return Bundle()
    return Bundle().apply {
      putString(KEY_PAYLOAD, newest.readText())
      putLong(KEY_WRITTEN_AT, newest.lastModified())
    }
  }

  private fun callerSharesOurSignature(context: Context): Boolean {
    val callingUid = Binder.getCallingUid()
    if (callingUid == Process.myUid()) return true
    val match = context.packageManager.checkSignatures(callingUid, Process.myUid())
    return match == PackageManager.SIGNATURE_MATCH
  }

  private fun newestAutomaticBackup(context: Context): File? {
    val dir = documentsDir(context)
    val candidates = dir.listFiles { file: File ->
      file.isFile && file.name.startsWith(AUTOMATIC_PREFIX) && file.name.endsWith(".json")
    } ?: return null
    return candidates.maxByOrNull { it.lastModified() }
  }

  // A provider has to exist as a component, but this one is a single `call`
  // endpoint: it stores nothing and exposes no table.
  override fun query(
    uri: Uri,
    projection: Array<out String>?,
    selection: String?,
    selectionArgs: Array<out String>?,
    sortOrder: String?,
  ): Cursor? = null

  override fun getType(uri: Uri): String? = null

  override fun insert(uri: Uri, values: ContentValues?): Uri? = null

  override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

  override fun update(
    uri: Uri,
    values: ContentValues?,
    selection: String?,
    selectionArgs: Array<out String>?,
  ): Int = 0
}
