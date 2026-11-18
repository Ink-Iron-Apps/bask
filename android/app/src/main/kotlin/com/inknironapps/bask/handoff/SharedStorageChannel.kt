package com.inknironapps.bask.handoff

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Access to the device's shared storage root, and to the permission that makes
 * it readable and writable.
 *
 * Downloads normally live in app-private storage, which Android deletes with
 * the app. That is the right default, but it also means a rename, a reinstall
 * or a change of signing key takes a whole offline library with it. A folder in
 * shared storage survives all three, so a library left there by a predecessor
 * install can be adopted by this one as plain files — no signature-matched
 * provider, and no requirement that both apps carry the same signing key.
 *
 * Two eras, because the app supports API 25 upward:
 *  - API 30+ has no runtime permission for arbitrary shared-storage access.
 *    `MANAGE_EXTERNAL_STORAGE` is granted on a Settings screen the app can only
 *    open, never on a dialog it can show.
 *  - API 25-29 treat `WRITE_EXTERNAL_STORAGE` as an ordinary runtime
 *    permission, which does grant plain-path access to the shared volume.
 *
 * Android TV generally has no activity for the Settings screen, so
 * [canRequestAccess] reports whether asking is even possible. A caller that
 * gets false should stay in app-private storage rather than offer something
 * that cannot be granted.
 */
class SharedStorageChannel(
  private val context: Context,
  private val activityProvider: () -> Activity?,
) {
  companion object {
    /** Request code for the pre-API-30 runtime permission. */
    const val LEGACY_WRITE_REQUEST_CODE = 0x5B45

    private const val LEGACY_WRITE_PERMISSION = android.Manifest.permission.WRITE_EXTERNAL_STORAGE

    /**
     * Whether this device grants shared-storage access on a Settings screen
     * rather than a runtime dialog.
     */
    private val usesManageAllFiles: Boolean
      get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
  }

  fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "getSharedRoot" -> result.success(sharedRoot())
      "hasAccess" -> result.success(hasAccess())
      "canRequestAccess" -> result.success(canRequestAccess())
      "requestAccess" -> result.success(requestAccess())
      else -> result.notImplemented()
    }
  }

  /**
   * The shared volume's root, or null when there is none mounted.
   *
   * Deliberately not `path_provider`'s external storage directory: that returns
   * the app-private `Android/data/<package>/files`, which Android 11 hides from
   * other apps and deletes on uninstall — both of the things a shared folder
   * exists to avoid.
   */
  private fun sharedRoot(): String? {
    if (Environment.getExternalStorageState() != Environment.MEDIA_MOUNTED) return null
    @Suppress("DEPRECATION")
    return Environment.getExternalStorageDirectory()?.absolutePath
  }

  private fun hasAccess(): Boolean {
    if (sharedRoot() == null) return false
    if (usesManageAllFiles) return Environment.isExternalStorageManager()
    return context.checkSelfPermission(LEGACY_WRITE_PERMISSION) == PackageManager.PERMISSION_GRANTED
  }

  /**
   * Whether access can be asked for at all.
   *
   * On API 30+ this is whether the Settings screen resolves to an activity.
   * Android TV usually has no such screen, and firing an intent nothing
   * handles would throw rather than ask.
   */
  private fun canRequestAccess(): Boolean {
    if (sharedRoot() == null) return false
    if (!usesManageAllFiles) return true
    return manageAllFilesIntent().resolveActivity(context.packageManager) != null
  }

  private fun manageAllFilesIntent(): Intent =
    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${context.packageName}"))

  /**
   * Starts the grant, returning whether anything was actually started.
   *
   * Never reports the outcome of the grant itself: on API 30+ the viewer leaves
   * for a Settings screen and comes back whenever they come back, so the caller
   * re-reads [hasAccess] on resume instead of waiting on a result here.
   */
  private fun requestAccess(): Boolean {
    if (hasAccess()) return true
    val activity = activityProvider() ?: return false
    if (!usesManageAllFiles) {
      activity.requestPermissions(arrayOf(LEGACY_WRITE_PERMISSION), LEGACY_WRITE_REQUEST_CODE)
      return true
    }
    val intent = manageAllFilesIntent()
    if (intent.resolveActivity(context.packageManager) == null) return false
    return try {
      activity.startActivity(intent)
      true
    } catch (error: Exception) {
      false
    }
  }
}
