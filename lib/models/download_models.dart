// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

import '../utils/formatters.dart';

part 'download_models.freezed.dart';

/// How many unwatched episodes a sync rule keeps when the viewer did not say.
///
/// "Unwatched" describes which episodes qualify, not how many to hold, and the
/// two were conflated: picking it with Keep synced stored a count of 0, which
/// the executor reads as "every episode matching the filter". A show with four
/// unwatched seasons therefore downloaded four seasons and kept doing it as
/// episodes aired — on a TV with a few hundred MB free that is the whole disk
/// for one show. A window is what the rule is for; the next ten episodes is
/// more than anyone watches before the next sync pass.
///
/// Lives here rather than beside the dialog that applies it because the
/// database needs the same number for the v24 migration, and the dialog layer
/// is downstream of the database.
const int defaultUnwatchedSyncCount = 10;

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

    /// Epoch milliseconds when the download completed, persisted on the row
    /// and carried through progress events so sort-by-download-date works
    /// without a database read.
    int? downloadedAt,
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
