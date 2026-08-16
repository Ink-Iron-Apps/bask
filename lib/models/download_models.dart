// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

import '../utils/formatters.dart';

part 'download_models.freezed.dart';

/// Fewest downloads that may run at once. Zero would stall the queue entirely.
const minConcurrentDownloads = 1;

/// Most downloads that may run at once.
///
/// Raising this is genuinely risky, not merely inadvisable. Measured against a
/// Plex Media Server at three slots, every transfer failed within a second or
/// two of starting, at 3-7% progress: the task reported waitingToRetry, the
/// retry produced a fresh task id, the stale-task guard cancelled it, and the
/// queue thrashed between items without finishing any of them. One slot on the
/// same server downloads steadily with no retries and no cancellations.
const maxConcurrentDownloads = 5;

/// Concurrency used when the setting has never been written.
///
/// One, because that is what a Plex server was observed to tolerate. The
/// setting exists for servers that handle more; the default must not gamble a
/// working download queue on the assumption that they do.
const defaultConcurrentDownloads = 1;

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
