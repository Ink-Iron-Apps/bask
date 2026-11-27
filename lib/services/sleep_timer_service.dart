import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/app_logger.dart';

/// Service to manage sleep timer functionality
/// Allows setting a timer to pause/stop playback after a specified duration
class SleepTimerService extends ChangeNotifier {
  static final SleepTimerService _instance = SleepTimerService._internal();
  factory SleepTimerService() => _instance;
  SleepTimerService._internal() : _now = DateTime.now;

  @visibleForTesting
  SleepTimerService.withClock(DateTime Function() now) : _now = now;
  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _endTime;
  Duration? _duration;
  Duration? _originalDuration;
  Object? _playbackOwner;
  VoidCallback? _onTimerComplete;
  bool _needsRestart = false;
  int _restartVideosRemaining = 0;
  bool _restartUntilQueueEnd = false;

  /// Items still to finish before the timer fires, or 0 when not armed this way.
  int _videosRemaining = 0;

  /// Armed to run until the queue has nothing left to play.
  bool _untilQueueEnd = false;
  final StreamController<void> _completedController = StreamController<void>.broadcast();
  final StreamController<void> _promptController = StreamController<void>.broadcast();

  /// Emits when the sleep timer completes (not when cancelled)
  Stream<void> get onCompleted => _completedController.stream;

  /// Emits when the timer fires and wants to show a "still watching?" prompt
  Stream<void> get onPrompt => _promptController.stream;

  bool get isActive => (_timer != null && _timer!.isActive) || _videosRemaining > 0 || _untilQueueEnd;

  /// Whether the sleep timer is armed to fire at the end of a number of videos,
  /// or at the end of the queue, rather than after a fixed duration.
  bool get isEndOfVideoMode => _videosRemaining > 0 || _untilQueueEnd;

  /// Whether it is waiting for the queue to run out rather than counting items.
  bool get isQueueEndMode => _untilQueueEnd;

  /// Items still to finish before the timer fires. Zero when it is not armed
  /// this way; 1 during the last item, whatever it was originally set to.
  int get videosRemaining => _videosRemaining;

  /// The time when the timer will complete
  DateTime? get endTime => _endTime;

  /// The original duration of the timer
  Duration? get duration => _duration;

  /// The user-selected duration (unmodified by extendTimer)
  Duration? get originalDuration => _originalDuration;

  Duration? get remainingTime {
    if (_endTime == null) return null;
    final remaining = _endTime!.difference(_now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Replace the playback target without changing the selected timer or deadline.
  void bindPlayback({required Object owner, required VoidCallback onComplete}) {
    _playbackOwner = owner;
    _onTimerComplete = onComplete;
  }

  /// Release the current playback target and restart its timer on the next session.
  /// A superseded owner cannot detach its successor or restart the countdown.
  void unbindPlayback(Object owner) {
    if (!identical(_playbackOwner, owner)) return;

    _playbackOwner = null;
    _onTimerComplete = null;
    if (isActive || _originalDuration != null) {
      _needsRestart = true;
      _restartVideosRemaining = _videosRemaining;
      _restartUntilQueueEnd = _untilQueueEnd;
    }
  }

  void startTimer(Duration duration) {
    cancelTimer();

    _originalDuration = duration;
    _duration = duration;
    _endTime = _now().add(duration);

    appLogger.d('Sleep timer started: ${duration.inMinutes} minutes');

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = remainingTime;

      if (remaining == null || remaining.inSeconds <= 0) {
        appLogger.d('Sleep timer completed - showing prompt');
        _stopTimerOnly();
        _promptController.add(null);
      } else {
        notifyListeners();
      }
    });

    notifyListeners();
  }

  /// Arm the sleep timer to fire when the current video reaches its end.
  void armEndOfVideo() => armEndOfVideos(1);

  /// Arm the sleep timer to fire after [count] videos have finished.
  ///
  /// Unlike [startTimer], no periodic timer runs — playback completion is
  /// reported externally via [notifyVideoCompleted]. A count above one leaves
  /// the intervening completions to the player's normal autoplay, so the queue
  /// keeps advancing until the last one.
  /// Arm the sleep timer to fire when the queue has nothing left to play.
  ///
  /// The count is unknowable up front — a queue can be a playlist, a shuffled
  /// list, or a series the server extends as it goes — so this asks the player
  /// at each completion whether anything follows, rather than counting.
  void armEndOfQueue() {
    cancelTimer();
    _untilQueueEnd = true;
    appLogger.d('Sleep timer armed: end of queue');
    notifyListeners();
  }

  void armEndOfVideos(int count) {
    cancelTimer();
    if (count < 1) return;

    _videosRemaining = count;

    appLogger.d('Sleep timer armed: end of $count video(s)');
    notifyListeners();
  }

  /// Notify the service that the currently playing video has completed.
  ///
  /// Returns true when that completion is the one the timer was waiting for,
  /// so the caller can stop rather than advance; false means the timer is
  /// either not armed this way or still counting, and playback should carry on
  /// as normal. Safe to call unconditionally.
  bool notifyVideoCompleted({bool hasNext = false}) {
    if (_untilQueueEnd) {
      if (hasNext) {
        appLogger.d('Sleep timer: queue still has items');
        return false;
      }
      appLogger.d('Sleep timer (end of queue) triggered');
      _untilQueueEnd = false;
      _executeCallback();
      notifyListeners();
      return true;
    }

    if (_videosRemaining < 1) return false;

    _videosRemaining--;
    if (_videosRemaining > 0) {
      appLogger.d('Sleep timer: $_videosRemaining video(s) to go');
      notifyListeners();
      return false;
    }

    appLogger.d('Sleep timer (end of video) triggered');
    _executeCallback();
    notifyListeners();
    return true;
  }

  /// Cancel the timer configuration and pending restart, keeping playback bound.
  void cancelTimer() {
    if (_timer != null ||
        _originalDuration != null ||
        _videosRemaining > 0 ||
        _needsRestart ||
        _restartVideosRemaining > 0) {
      appLogger.d('Sleep timer cancelled');
      _timer?.cancel();
      _timer = null;
      _endTime = null;
      _duration = null;
      _originalDuration = null;
      _needsRestart = false;
      _videosRemaining = 0;
      _untilQueueEnd = false;
      _restartVideosRemaining = 0;
      _restartUntilQueueEnd = false;
      notifyListeners();
    }
  }

  void restartTimer() {
    if (_originalDuration != null) {
      startTimer(_originalDuration!);
    }
  }

  /// Restart the timer if it was marked for restart (new playback session).
  void restartIfNeeded() {
    if (!_needsRestart) return;
    _needsRestart = false;

    if (_restartUntilQueueEnd) {
      _restartUntilQueueEnd = false;
      armEndOfQueue();
    } else if (_restartVideosRemaining > 0) {
      final remaining = _restartVideosRemaining;
      _restartVideosRemaining = 0;
      armEndOfVideos(remaining);
    } else if (_originalDuration != null) {
      startTimer(_originalDuration!);
    }
  }

  void extendTimer(Duration additionalTime) {
    if (_endTime != null) {
      _endTime = _endTime!.add(additionalTime);
      _duration = _duration != null ? _duration! + additionalTime : additionalTime;
      appLogger.d('Sleep timer extended by ${additionalTime.inMinutes} minutes');
      notifyListeners();
    }
  }

  /// Stop the countdown but preserve the selection and playback binding for
  /// the still-watching prompt's restart flow.
  void _stopTimerOnly() {
    _timer?.cancel();
    _timer = null;
    _endTime = null;
    _duration = null;
    notifyListeners();
  }

  void _executeCallback() {
    if (_onTimerComplete != null) {
      try {
        _onTimerComplete!();
      } catch (e) {
        appLogger.e('Error executing sleep timer callback', error: e);
      }
    }
    _completedController.add(null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _playbackOwner = null;
    _onTimerComplete = null;
    _completedController.close();
    _promptController.close();
    super.dispose();
  }
}
