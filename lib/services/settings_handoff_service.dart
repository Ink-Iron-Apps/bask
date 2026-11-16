import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

/// Settings a previous install of this app handed over.
class HandedOverSettings {
  /// The export JSON, in the same shape a settings export file holds.
  final String payload;

  /// When the previous install wrote it.
  final DateTime writtenAt;

  /// The authority it came from, for the log and for the prompt.
  final String authority;

  const HandedOverSettings({required this.payload, required this.writtenAt, required this.authority});
}

/// Asks a previous install of this app, under an applicationId this app used
/// to ship as, for the settings it was holding.
///
/// Renaming an Android app changes its applicationId, which makes it a
/// different app in a different sandbox with no upgrade path from the old one.
/// The old install's `SettingsHandoffProvider` is the only route across, and
/// it answers only an app signed with the same key.
class SettingsHandoffService {
  SettingsHandoffService._();

  static const MethodChannel _channel = MethodChannel('com.plezy/settings_handoff');

  /// Authorities to ask, newest predecessor first.
  ///
  /// Every applicationId this app has shipped under belongs here, forever: an
  /// install that sat untouched through two renames can still be the one
  /// holding the settings. The provider authority is the applicationId plus
  /// `.settingshandoff`, so an entry is only ever added, never edited.
  static const List<String> legacyAuthorities = ['com.inknironapps.plexy.settingshandoff'];

  @visibleForTesting
  static MethodChannel channel = _channel;

  /// Replaces the platform gate under test.
  ///
  /// Without it every case here skips off Android, and a suite that runs on
  /// Linux and Windows would cover the channel contract nowhere at all.
  @visibleForTesting
  static bool? debugSupportedOverride;

  /// Whether this platform has a predecessor app to ask. Android only: the
  /// handoff is a ContentProvider between two applicationIds.
  static bool get isSupported => debugSupportedOverride ?? Platform.isAndroid;

  /// The settings a predecessor is holding, or null when there is no
  /// predecessor, it has nothing to give, or this platform has no handoff.
  static Future<HandedOverSettings?> readFromPreviousInstall({List<String> authorities = legacyAuthorities}) async {
    if (!isSupported || authorities.isEmpty) return null;
    try {
      final result = await channel.invokeMapMethod<String, Object?>('readPreviousInstallSettings', {
        'authorities': authorities,
      });
      final payload = result?['payload'];
      if (payload is! String || payload.isEmpty) return null;
      final writtenAt = result?['writtenAt'];
      return HandedOverSettings(
        payload: payload,
        // UTC, because the value crossed a platform boundary as epoch
        // milliseconds and has no zone of its own.
        writtenAt: DateTime.fromMillisecondsSinceEpoch(writtenAt is int ? writtenAt : 0, isUtc: true),
        authority: result?['authority'] is String ? result!['authority']! as String : authorities.first,
      );
    } on MissingPluginException {
      // A build without the native half — a test host, or a platform that
      // never had a predecessor to hand anything over.
      return null;
    } on PlatformException catch (error) {
      appLogger.w('Settings handoff from a previous install failed', error: error);
      return null;
    }
  }
}
