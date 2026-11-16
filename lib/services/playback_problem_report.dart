import '../media/media_item.dart';
import '../utils/app_logger.dart';
import '../utils/storage_space.dart';
import '../widgets/video_controls/widgets/performance_overlay/performance_stats.dart';

/// Builds the text behind "Report a playback problem".
///
/// Stuttering, a silent audio dropout, subtitles that never appear — none of
/// them say anything useful after the fact. What settles them is the state the
/// player was in while it happened: which decoder, which output, how full the
/// cache was, how many frames went missing, how much room was left on the
/// device. The player already reads every one of those for its performance
/// overlay; this captures them the moment someone says something is wrong,
/// next to the log lines from the same minute.
///
/// Pure text assembly so the shape of a report is testable, and so the caller
/// decides what happens to it — uploaded, copied, or written to a file.
String buildPlaybackProblemReport({
  required DateTime now,
  required String appVersion,
  required String platform,
  String? deviceModel,
  PerformanceStats? stats,
  MediaItem? item,
  StorageSpace? storage,
  List<LogEntry> logs = const [],
  int maxLogLines = 300,
}) {
  final out = StringBuffer()
    ..writeln('Bask playback problem report')
    ..writeln('Reported: ${now.toUtc().toIso8601String()}')
    ..writeln('App: $appVersion')
    ..writeln('Device: $platform${deviceModel == null ? '' : ' ($deviceModel)'}');

  if (storage != null) {
    out.writeln('Free space: ${_gb(storage.freeBytes)} of ${_gb(storage.totalBytes)}');
  }

  out.writeln();
  if (item == null) {
    out.writeln('Item: nothing playing');
  } else {
    out
      ..writeln('Item: ${item.displayTitle}')
      ..writeln('Item id: ${item.globalKey}');
  }

  out.writeln();
  if (stats == null) {
    // Worth saying out loud rather than leaving a gap: "the player told us
    // nothing" is itself a finding, and a common one when it has wedged.
    out.writeln('Player state: unavailable');
  } else {
    out
      ..writeln('Player: ${stats.playerType}')
      ..writeln(
        'Video: ${stats.videoCodec ?? 'unknown'} '
        '${stats.videoWidth ?? '?'}x${stats.videoHeight ?? '?'} '
        '@ ${_num(stats.videoFps)} fps',
      )
      ..writeln('Decoder: ${stats.videoDecoderName ?? 'unknown'} (hwdec ${stats.hwdecCurrent ?? 'none'})')
      ..writeln('Output: ${stats.currentVo ?? 'unknown'}, tunneled ${stats.tunneledPlayback}')
      ..writeln('Pixel format: ${stats.pixelformat ?? 'unknown'} / hw ${stats.hwPixelformat ?? 'none'}')
      ..writeln('Colour: ${stats.colormatrix ?? '?'} ${stats.primaries ?? '?'} ${stats.gamma ?? '?'}')
      ..writeln(
        'Audio: ${stats.audioCodec ?? 'unknown'} ${stats.audioChannels ?? '?'} '
        '${stats.audioSamplerate ?? '?'} Hz'
        '${stats.audioPassthroughFormat == null ? '' : ' passthrough ${stats.audioPassthroughFormat}'}',
      )
      ..writeln('Rendered: ${_num(stats.actualFps)} fps, display ${_num(stats.displayFps)} fps')
      ..writeln('Dropped frames: ${stats.frameDropCount ?? 0} (decoder ${stats.decoderFrameDropCount ?? 0})')
      ..writeln('A/V sync change: ${_num(stats.avsyncChange)}')
      ..writeln(
        'Cache: ${_mb(stats.cacheUsed)} of ${_mb(stats.cacheLimit)}, '
        '${_num(stats.cacheDuration)} s buffered, ${_num(stats.cacheSpeed)} B/s',
      );
    if (stats.dvConversionActive) {
      out.writeln(
        'Dolby Vision: mode ${stats.dvConversionMode}, profile ${stats.dvSourceProfile ?? '?'}, '
        'path ${stats.dvPlaybackPath ?? '?'}, failures ${stats.dvRpuConversionFailures ?? 0}',
      );
    }
  }

  out
    ..writeln()
    ..writeln('--- log (newest last, $maxLogLines lines at most) ---');

  // [MemoryLogOutput.getLogs] hands back newest first; a log reads in the
  // order things happened, and the newest lines are the ones worth keeping
  // when there are too many.
  final kept = logs.take(maxLogLines).toList().reversed;
  for (final entry in kept) {
    out.writeln('${entry.timestamp.toIso8601String()} [${entry.level.name}] ${entry.message}');
    if (entry.error != null) out.writeln('  error: ${entry.error}');
  }

  return out.toString();
}

String _num(double? value) => value == null ? '?' : value.toStringAsFixed(2);

String _mb(int? bytes) => bytes == null ? '?' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _gb(int bytes) => '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
