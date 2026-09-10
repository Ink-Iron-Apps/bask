import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// On-disk home for the player's read-ahead buffer.
///
/// Buffering into memory is capped by the device heap — on Android the cap is
/// tens of megabytes, which is a minute or two of a high-bitrate remux. Pausing
/// on a weak connection therefore buys far less than it appears to. Pointing
/// mpv's cache at storage instead lifts that ceiling to whatever the disk can
/// take, so a pause can build a genuinely useful lead.
///
/// The payload is disposable: it is a copy of what the server already has, and
/// mpv writes it per playback session. Anything left behind is either a session
/// that ended badly or one still running, so old files are pruned rather than
/// kept.
class PlaybackDiskCache {
  PlaybackDiskCache._();

  /// How long a cache file may sit before it is considered abandoned.
  ///
  /// Long enough not to disturb a paused film, short enough that a crashed
  /// session does not leave gigabytes parked on the device.
  static const Duration retention = Duration(hours: 2);

  static const String _directoryName = 'playback-cache';

  /// The cache directory, created if missing, or `null` if it cannot be made.
  static Future<Directory?> ensureDirectory() async {
    try {
      final base = await getTemporaryDirectory();
      final directory = Directory(path.join(base.path, _directoryName));
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }
      return directory;
    } catch (e) {
      appLogger.w('Playback disk cache unavailable', error: e);
      return null;
    }
  }

  /// Deletes cache files last modified more than [retention] ago.
  ///
  /// Returns the number of bytes reclaimed. A file that vanishes mid-sweep —
  /// mpv cleaning up its own session — is not an error.
  static Future<int> prune(Directory directory, {DateTime? now, Duration retention = retention}) async {
    if (!directory.existsSync()) return 0;

    final cutoff = (now ?? DateTime.now()).subtract(retention);
    var reclaimed = 0;
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      try {
        final stat = entity.statSync();
        if (!stat.modified.isBefore(cutoff)) continue;
        reclaimed += stat.size;
        entity.deleteSync();
      } on FileSystemException catch (e) {
        // Still held open by a running session, or already gone.
        appLogger.d('Could not prune ${entity.path}', error: e);
      }
    }
    if (reclaimed > 0) {
      appLogger.i('Pruned ${(reclaimed / (1024 * 1024)).toStringAsFixed(1)} MB of playback cache');
    }
    return reclaimed;
  }

  /// Bytes free on the volume holding [directory], or null if unknown.
  ///
  /// There is no Dart API for this, and the cache lives on the same partition
  /// as the app's data, so ask the platform. A TV's data partition can be 4 GB
  /// total — asking mpv to buffer more than fits does not fail cleanly: it
  /// fills the volume, and Android reclaims the app's cache directory to
  /// recover, taking the extracted subtitle fonts with it.
  static Future<int?> freeBytes(Directory directory) async {
    if (!Platform.isAndroid && !Platform.isLinux && !Platform.isMacOS) return null;
    try {
      final result = await Process.run('df', ['-k', directory.path]);
      if (result.exitCode != 0) return null;
      final lines = const LineSplitter().convert(result.stdout.toString()).where((l) => l.trim().isNotEmpty);
      if (lines.length < 2) return null;
      final fields = lines.last.trim().split(RegExp(r'\s+'));
      // df -k: Filesystem, 1K-blocks, Used, Available, ...
      final availableKb = fields.length > 3 ? int.tryParse(fields[3]) : null;
      return availableKb == null ? null : availableKb * 1024;
    } catch (e) {
      appLogger.d('Could not measure free space for ${directory.path}', error: e);
      return null;
    }
  }

  /// Prunes the real cache directory, if there is one.
  static Future<void> pruneDefault() async {
    final directory = await ensureDirectory();
    if (directory == null) return;
    await prune(directory);
  }
}
