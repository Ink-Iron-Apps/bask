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
