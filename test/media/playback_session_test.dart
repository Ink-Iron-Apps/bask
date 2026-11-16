import 'package:flutter_test/flutter_test.dart';
import 'package:bask/media/ids.dart';
import 'package:bask/media/media_backend.dart';
import 'package:bask/media/playback_session.dart';

PlaybackSession session({StreamDecision? video, StreamDecision? audio, int? positionMs, int? durationMs}) =>
    PlaybackSession(
      serverId: ServerId('server-1'),
      backend: MediaBackend.plex,
      sessionId: 'session-1',
      video: video,
      audio: audio,
      positionMs: positionMs,
      durationMs: durationMs,
    );

const directPlay = StreamDecision(method: StreamMethod.directPlay);
const directStream = StreamDecision(method: StreamMethod.directStream);
const transcode = StreamDecision(method: StreamMethod.transcode);

void main() {
  group('PlaybackSession.effectiveMethod', () {
    test('reports the heaviest work the server is doing, not the first track', () {
      // The mixed session is the common one: a client that can take the video
      // untouched but needs the audio re-encoded is still costing CPU, and a
      // summary that led with the video would call it a direct play.
      expect(session(video: directPlay, audio: transcode).effectiveMethod, StreamMethod.transcode);
      expect(session(video: transcode, audio: directPlay).effectiveMethod, StreamMethod.transcode);
      expect(session(video: directPlay, audio: directStream).effectiveMethod, StreamMethod.directStream);
      expect(session(video: directPlay, audio: directPlay).effectiveMethod, StreamMethod.directPlay);
    });

    test('an unreported stream does not invent work', () {
      expect(session().effectiveMethod, StreamMethod.directPlay);
      expect(session(video: transcode).effectiveMethod, StreamMethod.transcode);
    });
  });

  group('PlaybackSession.progress', () {
    test('is null unless both ends are known', () {
      expect(session().progress, isNull);
      expect(session(positionMs: 1000).progress, isNull);
      expect(session(durationMs: 1000).progress, isNull);
      // A zero duration is a server that has not worked it out yet, not a
      // finished item — dividing by it would be infinity on a progress bar.
      expect(session(positionMs: 1000, durationMs: 0).progress, isNull);
    });

    test('clamps a position past the end', () {
      // Plex keeps reporting viewOffset for a moment after the item ends.
      expect(session(positionMs: 2000, durationMs: 1000).progress, 1.0);
      expect(session(positionMs: 500, durationMs: 1000).progress, 0.5);
    });
  });

  test('globalKey distinguishes equal session ids on different servers', () {
    final a = PlaybackSession(serverId: ServerId('a'), backend: MediaBackend.plex, sessionId: '1');
    final b = PlaybackSession(serverId: ServerId('b'), backend: MediaBackend.jellyfin, sessionId: '1');
    expect(a.globalKey, isNot(b.globalKey));
  });
}
