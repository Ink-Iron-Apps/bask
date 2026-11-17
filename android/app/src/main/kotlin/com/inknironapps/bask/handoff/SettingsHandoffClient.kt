package com.inknironapps.bask.handoff

import android.content.Context
import android.net.Uri
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The other half of [SettingsHandoffProvider]: asks a previous install of this
 * app, under its old applicationId, for the settings it was holding.
 *
 * Dart supplies the authorities to try, because which applicationIds this app
 * has previously shipped under is a fact about the app's history rather than
 * about Android, and it belongs with the rest of the migration logic.
 */
class SettingsHandoffClient(private val context: Context) {

  companion object {
    private const val TAG = "SettingsHandoff"
  }

  fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "readPreviousInstallSettings" -> {
        val authorities = call.argument<List<String>>("authorities").orEmpty()
        result.success(readFirstAvailable(authorities))
      }
      "readDownloadManifest" -> {
        val authorities = call.argument<List<String>>("authorities").orEmpty()
        result.success(readFirstManifest(authorities))
      }
      "copyHandoffFile" -> {
        val authority = call.argument<String>("authority")
        val segment = call.argument<String>("segment")
        val relativePath = call.argument<String>("relativePath")
        val destination = call.argument<String>("destination")
        if (authority == null || segment == null || destination == null) {
          result.error("bad_arguments", "authority, segment and destination are required", null)
          return
        }
        try {
          result.success(copyFile(authority, segment, relativePath, destination))
        } catch (error: SecurityException) {
          result.error("refused", error.message, null)
        } catch (error: Exception) {
          result.error("copy_failed", error.message, null)
        }
      }
      else -> result.notImplemented()
    }
  }

  private fun readFirstAvailable(authorities: List<String>): Map<String, Any?>? {
    for (authority in authorities) {
      val payload = read(authority) ?: continue
      return payload
    }
    return null
  }

  private fun readFirstManifest(authorities: List<String>): Map<String, Any?>? {
    for (authority in authorities) {
      val manifest = readManifest(authority) ?: continue
      return manifest
    }
    return null
  }

  private fun readManifest(authority: String): Map<String, Any?>? {
    val uri = Uri.parse("content://$authority")
    return try {
      val bundle = context.contentResolver.call(
        uri,
        SettingsHandoffProvider.METHOD_READ_DOWNLOAD_MANIFEST,
        null,
        null,
      ) ?: return null
      val paths = bundle.getStringArrayList(SettingsHandoffProvider.KEY_DOWNLOAD_PATHS) ?: arrayListOf()
      val sizes = bundle.getLongArray(SettingsHandoffProvider.KEY_DOWNLOAD_SIZES) ?: longArrayOf()
      mapOf(
        "authority" to authority,
        "paths" to paths,
        "sizes" to sizes.toList(),
        "databaseSize" to bundle.getLong(SettingsHandoffProvider.KEY_DATABASE_SIZE),
      )
    } catch (error: SecurityException) {
      Log.w(TAG, "Download manifest refused by $authority", error)
      null
    } catch (error: Exception) {
      Log.d(TAG, "No download handoff from $authority: ${error.message}")
      null
    }
  }

  /**
   * Copies one file out of the previous install into [destination].
   *
   * Writes to a sibling `.part` file and renames on success, so an interrupt
   * leaves no half-file that a later run would mistake for a finished one by
   * its size.
   */
  private fun copyFile(authority: String, segment: String, relativePath: String?, destination: String): Long {
    val builder = Uri.parse("content://$authority").buildUpon().appendPath(segment)
    relativePath?.split('/')?.filter { it.isNotEmpty() }?.forEach { builder.appendPath(it) }
    val uri = builder.build()

    val target = java.io.File(destination)
    target.parentFile?.mkdirs()
    val partial = java.io.File(destination + ".part")
    if (partial.exists()) partial.delete()

    var copied = 0L
    context.contentResolver.openInputStream(uri).use { input ->
      if (input == null) throw java.io.IOException("Nothing to read at $uri")
      partial.outputStream().use { output ->
        val buffer = ByteArray(1 shl 16)
        while (true) {
          val read = input.read(buffer)
          if (read <= 0) break
          output.write(buffer, 0, read)
          copied += read
        }
        output.flush()
      }
    }
    if (target.exists()) target.delete()
    if (!partial.renameTo(target)) {
      partial.delete()
      throw java.io.IOException("Could not move the copied file into place at $destination")
    }
    return copied
  }

  private fun read(authority: String): Map<String, Any?>? {
    val uri = Uri.parse("content://$authority")
    return try {
      val bundle = context.contentResolver.call(uri, SettingsHandoffProvider.METHOD_READ_SETTINGS, null, null)
      val json = bundle?.getString(SettingsHandoffProvider.KEY_PAYLOAD) ?: return null
      mapOf(
        "payload" to json,
        "writtenAt" to bundle.getLong(SettingsHandoffProvider.KEY_WRITTEN_AT),
        "authority" to authority,
      )
    } catch (error: SecurityException) {
      // A provider under this authority exists but will not talk to us. That
      // is the signature check doing its job, not a condition to retry.
      Log.w(TAG, "Refused by $authority", error)
      null
    } catch (error: Exception) {
      // No such provider is the ordinary case: there is no previous install.
      Log.d(TAG, "No settings handoff from $authority: ${error.message}")
      null
    }
  }
}
