package com.inknironapps.bask.handoff

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.Process
import java.io.File
import java.io.FileNotFoundException

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

    /** The `call` method a successor invokes to see what downloads exist. */
    const val METHOD_READ_DOWNLOAD_MANIFEST = "readDownloadManifest"

    /** Bundle key holding download paths, relative to the downloads folder. */
    const val KEY_DOWNLOAD_PATHS = "downloadPaths"

    /** Bundle key holding each path's size in bytes, in the same order. */
    const val KEY_DOWNLOAD_SIZES = "downloadSizes"

    /** Bundle key holding the downloads database's size, or 0 when absent. */
    const val KEY_DATABASE_SIZE = "databaseSize"

    /** First path segment of a URI naming a file inside the downloads folder. */
    const val SEGMENT_DOWNLOADS = "downloads"

    /** First path segment of the URI naming the downloads database itself. */
    const val SEGMENT_DATABASE = "database"

    /**
     * The downloads database's file name, which keeps the old app's name
     * because it is a file already on disk rather than a label.
     */
    private const val DOWNLOADS_DATABASE = "plezy_downloads.db"

    /** Where downloads live: the app directory's own `downloads` folder. */
    private fun downloadsDir(context: Context): File = File(documentsDir(context), SEGMENT_DOWNLOADS)

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
    return when (method) {
      METHOD_READ_SETTINGS -> {
        val newest = newestAutomaticBackup(context) ?: return Bundle()
        Bundle().apply {
          putString(KEY_PAYLOAD, newest.readText())
          putLong(KEY_WRITTEN_AT, newest.lastModified())
        }
      }
      METHOD_READ_DOWNLOAD_MANIFEST -> downloadManifest(context)
      else -> null
    }
  }

  /**
   * Every downloaded file this install holds, with its size, plus the size of
   * the database that describes them.
   *
   * Paths are relative to the downloads folder so the successor can rebuild
   * them under its own app directory, which is at a different absolute path.
   * Sizes travel with them because the successor needs the total before it
   * offers to copy tens of gigabytes, and needs each one to tell a finished
   * copy from an interrupted one without re-reading the source.
   *
   * Only the app-private downloads folder is served. A viewer who pointed
   * downloads at a custom location put them outside this sandbox already, and
   * a SAF tree permission cannot be handed to another app in any case, so
   * those are reported as absent rather than as something this can move.
   */
  private fun downloadManifest(context: Context): Bundle {
    val root = downloadsDir(context)
    val paths = ArrayList<String>()
    val sizes = ArrayList<Long>()
    if (root.isDirectory) {
      val prefix = root.absolutePath + File.separator
      root.walkTopDown().forEach { file ->
        if (!file.isFile) return@forEach
        val absolute = file.absolutePath
        if (!absolute.startsWith(prefix)) return@forEach
        paths.add(absolute.substring(prefix.length).replace(File.separatorChar, '/'))
        sizes.add(file.length())
      }
    }
    val database = File(documentsDir(context), DOWNLOADS_DATABASE)
    return Bundle().apply {
      putStringArrayList(KEY_DOWNLOAD_PATHS, paths)
      putLongArray(KEY_DOWNLOAD_SIZES, sizes.toLongArray())
      putLong(KEY_DATABASE_SIZE, if (database.isFile) database.length() else 0L)
    }
  }

  /**
   * Streams one downloaded file, or the downloads database, read-only.
   *
   * The signature check is repeated here rather than trusted from [call]:
   * `openFile` is a separate entry point and a caller can reach it directly.
   *
   * Paths are resolved and then checked against the canonical root, so a
   * successor asking for `../../shared_prefs/...` gets a refusal rather than
   * whatever that resolves to. Canonical rather than textual comparison,
   * because a symlink inside the downloads folder would otherwise pass a
   * textual prefix test and read from outside it.
   */
  override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
    val context = context ?: return null
    if (!callerSharesOurSignature(context)) {
      throw SecurityException("Download handoff is limited to apps signed with the same key")
    }
    if (mode != "r") throw SecurityException("The download handoff is read-only")

    val segments = uri.pathSegments
    if (segments.isEmpty()) throw FileNotFoundException("No file named in $uri")

    val target = when (segments.first()) {
      SEGMENT_DATABASE -> File(documentsDir(context), DOWNLOADS_DATABASE)
      SEGMENT_DOWNLOADS -> {
        val relative = segments.drop(1).joinToString(File.separator)
        if (relative.isEmpty()) throw FileNotFoundException("No file named in $uri")
        resolveInside(downloadsDir(context), relative)
      }
      else -> throw FileNotFoundException("Unknown handoff path in $uri")
    }
    if (!target.isFile) throw FileNotFoundException("No such file: $uri")
    return ParcelFileDescriptor.open(target, ParcelFileDescriptor.MODE_READ_ONLY)
  }

  private fun resolveInside(root: File, relative: String): File {
    val candidate = File(root, relative)
    val canonicalRoot = root.canonicalFile
    var walker: File? = candidate.canonicalFile
    while (walker != null) {
      if (walker == canonicalRoot) return candidate
      walker = walker.parentFile
    }
    throw SecurityException("The handoff serves only files inside its downloads folder")
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
