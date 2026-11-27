import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:bask/media/media_backend.dart';
import 'package:bask/media/media_kind.dart';
import 'package:bask/services/playback_problem_report.dart';
import 'package:bask/utils/app_logger.dart';
import 'package:bask/utils/storage_space.dart';
import 'package:bask/widgets/video_controls/widgets/performance_overlay/performance_stats.dart';

import '../test_helpers/media_items.dart';

void main() {
  final now = DateTime.utc(2026, 9, 22, 20, 30);

  test('carries the state that explains a stutter', () {
    const stats = PerformanceStats(
      playerType: 'mpv',
      videoCodec: 'hevc',
      videoWidth: 3840,
      videoHeight: 2160,
      videoFps: 23.976,
      hwdecCurrent: 'mediacodec',
      frameDropCount: 47,
      decoderFrameDropCount: 3,
      cacheUsed: 12 * 1024 * 1024,
      cacheLimit: 64 * 1024 * 1024,
      cacheDuration: 4.5,
    );

    final report = buildPlaybackProblemReport(
      now: now,
      appVersion: '2.30.3+1',
      platform: 'Android',
      deviceModel: 'BRAVIA 4K',
      stats: stats,
      item: testMediaItem(id: 'ep-1', backend: MediaBackend.plex, kind: MediaKind.episode, title: 'Dulcinea'),
      storage: const StorageSpace(freeBytes: 1073741824, totalBytes: 4294967296),
    );

    expect(report, contains('BRAVIA 4K'));
    expect(report, contains('hevc'));
    expect(report, contains('mediacodec'));
    expect(report, contains('Dropped frames: 47 (decoder 3)'));
    expect(report, contains('12.0 MB of 64.0 MB'));
    expect(report, contains('Free space: 1.0 GB of 4.0 GB'));
  });

  test('says so when the player answered with nothing', () {
    // A player that has stopped answering is a description of the fault, not
    // a reason to send an empty report.
    final report = buildPlaybackProblemReport(now: now, appVersion: '2.30.3+1', platform: 'Android');

    expect(report, contains('Player state: unavailable'));
    expect(report, contains('Item: nothing playing'));
  });

  test('puts the log in the order things happened and keeps the newest', () {
    // MemoryLogOutput hands back newest first; a log that reads backwards is
    // worse than no log.
    final logs = [
      for (var i = 5; i >= 1; i--)
        LogEntry(
          timestamp: now.add(Duration(seconds: i)),
          level: Level.info,
          message: 'line $i',
        ),
    ];

    final report = buildPlaybackProblemReport(
      now: now,
      appVersion: '2.30.3+1',
      platform: 'Android',
      logs: logs,
      maxLogLines: 3,
    );

    expect(report.indexOf('line 3'), lessThan(report.indexOf('line 4')));
    expect(report, contains('line 5'));
    expect(report, isNot(contains('line 1')));
  });
}
