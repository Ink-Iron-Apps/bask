package com.edde746.plezy

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hands a downloaded APK to Android's package installer.
 *
 * Sideloaded builds update themselves from a GitHub release rather than a store, and Flutter
 * cannot start the install itself. The APK still goes through the system installer, which shows
 * its own confirmation: a sideloaded app cannot install silently, and should not be able to.
 */
class ApkInstallChannel(private val activity: Activity) {

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canRequestInstall" -> result.success(canRequestInstall())
            "openInstallPermissionSettings" -> result.success(openInstallPermissionSettings())
            "installApk" -> installApk(call.argument<String>("path"), result)
            else -> result.notImplemented()
        }
    }

    /**
     * Whether the user has granted "install unknown apps" for this app. Without it the installer
     * opens on a settings prompt instead of the confirmation, which reads as the update silently
     * failing.
     */
    private fun canRequestInstall(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return activity.packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("no_path", "No APK path supplied", null)
            return
        }
        val apk = File(path)
        if (!apk.isFile || apk.length() == 0L) {
            result.error("missing_apk", "APK not found or empty at $path", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", apk)
            activity.startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            )
            result.success(true)
        } catch (e: Exception) {
            result.error("install_failed", e.message ?: "Could not start the installer", null)
        }
    }
}
