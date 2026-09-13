import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';

/// Free and total bytes on the volume holding a directory.
///
/// Dart exposes no filesystem-statistics API, and the platform channels this
/// app already has do not carry one either, so ask `df`. Only the Unix-like
/// hosts answer; callers treat a null as "unknown" and carry on.
///
/// Worth knowing at all because a small volume fails in ways that do not look
/// like a storage problem: a TV's data partition can be 4 GB, and filling it
/// makes Android reclaim the app's cache directory, which used to take the
/// extracted subtitle fonts with it and silently stop subtitles rendering.
class StorageSpace {
  const StorageSpace({required this.freeBytes, required this.totalBytes});

  final int freeBytes;
  final int totalBytes;

  /// Fraction of the volume still free, 0..1.
  double get freeFraction => totalBytes <= 0 ? 1 : freeBytes / totalBytes;

  /// Under a gigabyte free, or under a tenth of the volume.
  ///
  /// Both limbs matter: a gigabyte is roughly one high-bitrate film's cache,
  /// and the proportional test catches a small volume that is merely full
  /// rather than small.
  bool get isLow => freeBytes < 1024 * 1024 * 1024 || freeFraction < 0.1;

  static Future<StorageSpace?> measure(Directory directory) async {
    if (!Platform.isAndroid && !Platform.isLinux && !Platform.isMacOS) return null;
    try {
      final result = await Process.run('df', ['-k', directory.path]);
      if (result.exitCode != 0) return null;
      final lines = const LineSplitter().convert(result.stdout.toString()).where((l) => l.trim().isNotEmpty);
      if (lines.length < 2) return null;
      // df -k: Filesystem, 1K-blocks, Used, Available, Use%, Mounted on
      final fields = lines.last.trim().split(RegExp(r'\s+'));
      if (fields.length < 4) return null;
      final totalKb = int.tryParse(fields[1]);
      final freeKb = int.tryParse(fields[3]);
      if (totalKb == null || freeKb == null) return null;
      return StorageSpace(freeBytes: freeKb * 1024, totalBytes: totalKb * 1024);
    } catch (e) {
      appLogger.d('Could not measure free space for ${directory.path}', error: e);
      return null;
    }
  }
}
