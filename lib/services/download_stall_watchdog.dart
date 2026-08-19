import 'dart:async';

/// Watches running downloads for one that has stopped moving.
///
/// A download can lose its transfer without losing its connection. The socket
/// stays open, both queues stay empty, and nothing further arrives — so the
/// platform reports neither progress nor failure and the task sits at whatever
/// percentage it reached. `background_downloader` cannot notice: on Android its
/// `requestTimeout` sets only `connectTimeout`, and `HttpURLConnection`'s read
/// timeout defaults to infinite, so the read blocks for as long as the socket
/// is held open.
///
/// Progress events are the heartbeat. When one stops arriving for [threshold],
/// the download is treated as stalled and handed back to the retry path, which
/// cancels the dead task and enqueues a fresh one.
class DownloadStallWatchdog {
  /// How long a running download may report nothing before it is considered
  /// stalled.
  ///
  /// Long enough to sit out an ordinary pause — a slow server, a moment of poor
  /// signal, a large moov atom being written — and short enough that a genuinely
  /// dead transfer does not waste the evening.
  static const Duration defaultThreshold = Duration(minutes: 2);

  DownloadStallWatchdog({
    required this.onStalled,
    this.threshold = defaultThreshold,
    this.checkInterval = const Duration(seconds: 30),
    this.clock = DateTime.now,
  });

  /// Restarts the download identified by the key it is given.
  final Future<void> Function(String globalKey) onStalled;

  /// Silence longer than this means the transfer is gone.
  final Duration threshold;

  /// How often the watched downloads are swept.
  final Duration checkInterval;

  /// Injectable so the sweep can be tested without waiting in real time.
  final DateTime Function() clock;

  final Map<String, DateTime> _lastProgressAt = {};
  final Set<String> _reported = {};
  Timer? _timer;

  /// Downloads currently being watched.
  Iterable<String> get watchedKeys => _lastProgressAt.keys;

  /// Records that [globalKey] is alive — starting, or reporting progress.
  ///
  /// Also clears any earlier stall verdict, so a download that recovers on its
  /// own is eligible to be reported again later.
  void markAlive(String globalKey) {
    _lastProgressAt[globalKey] = clock();
    _reported.remove(globalKey);
    _ensureTimer();
  }

  /// Stops watching [globalKey] — it finished, failed, or was cancelled.
  void forget(String globalKey) {
    _lastProgressAt.remove(globalKey);
    _reported.remove(globalKey);
    if (_lastProgressAt.isEmpty) _stopTimer();
  }

  void dispose() {
    _stopTimer();
    _lastProgressAt.clear();
    _reported.clear();
  }

  /// The downloads that have gone quiet for longer than the threshold.
  ///
  /// Each is reported once: the caller restarts it, and the fresh task marks it
  /// alive again. Without that the same stalled download would be reported on
  /// every sweep while its replacement was still being enqueued.
  List<String> stalledKeys() {
    final now = clock();
    final stalled = <String>[];
    for (final entry in _lastProgressAt.entries) {
      if (_reported.contains(entry.key)) continue;
      if (now.difference(entry.value) >= threshold) stalled.add(entry.key);
    }
    return stalled;
  }

  /// Runs one sweep, handing every newly stalled download to the callback.
  Future<void> checkNow() async {
    for (final globalKey in stalledKeys()) {
      _reported.add(globalKey);
      await onStalled(globalKey);
    }
  }

  void _ensureTimer() {
    _timer ??= Timer.periodic(checkInterval, (_) => unawaited(checkNow()));
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
