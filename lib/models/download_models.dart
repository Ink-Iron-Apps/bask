// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

import '../utils/formatters.dart';

part 'download_models.freezed.dart';

/// Fewest downloads that may run at once. Zero would stall the queue entirely.
const minConcurrentDownloads = 1;

/// Most downloads that may run at once.
///
/// A ceiling rather than a measured limit: three slots were verified against a
/// Plex server, and each additional slot divides the same server-side
/// throughput rather than adding to it.
const maxConcurrentDownloads = 5;

/// Concurrency used when the setting has never been written.
///
/// Three concurrent downloads were measured running continuously, both in the
/// foreground and with the app backgrounded and the screen locked. Two earlier
/// defects made concurrency look impossible and are fixed elsewhere: the
/// downloader promoted every task to the process's single foreground service
/// and WorkManager cancelled the ones that lost, and downloads requested the
/// part as playback so the server evicted each transfer as the next one
/// started.
const defaultConcurrentDownloads = 3;

enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
  partial, // Some episodes downloaded, but not all (for shows/seasons)
}

@freezed
sealed class DownloadProgress with _$DownloadProgress {
  const DownloadProgress._();

  const factory DownloadProgress({
    required String globalKey,
    required DownloadStatus status,
    @Default(0) int progress,
    @Default(0) int downloadedBytes,
    @Default(0) int totalBytes,
    @Default(0.0) double speed,
    String? errorMessage,
    String? currentFile,
    String? thumbPath,
  }) = _DownloadProgress;

  double get progressPercent => progress / 100.0;

  String get speedFormatted => ByteFormatter.formatSpeed(speed);

  bool get hasArtworkPaths => thumbPath != null;
}

@freezed
sealed class DeletionProgress with _$DeletionProgress {
  const DeletionProgress._();

  const factory DeletionProgress({
    required String globalKey,
    required String itemTitle,
    required int currentItem,
    required int totalItems,
    String? currentOperation,
  }) = _DeletionProgress;

  double get progressPercent => totalItems > 0 ? (currentItem / totalItems) : 0.0;

  int get progressPercentInt => (progressPercent * 100).round();

  bool get isComplete => currentItem >= totalItems;
}
