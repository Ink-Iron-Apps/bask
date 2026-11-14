import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_backend.dart';
import '../../media/media_server_client.dart';
import '../../media/playback_session.dart';
import '../../mixins/mounted_set_state_mixin.dart';
import '../../providers/multi_server_provider.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/dialogs.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';

/// What every server this user administers is streaming right now, and the two
/// things an owner wants to do about it: tell someone, and stop them.
///
/// Gated on [MultiServerManager.isOwnerOrAdmin] per server rather than
/// globally, because an account can own one server and be a guest on another —
/// asking the guest server returns a 403 that says nothing useful.
class ServerActivityScreen extends StatefulWidget {
  const ServerActivityScreen({super.key});

  @override
  State<ServerActivityScreen> createState() => _ServerActivityScreenState();
}

class _ServerActivityScreenState extends State<ServerActivityScreen> with MountedSetStateMixin {
  /// Poll cadence. Fast enough that a stop looks immediate and a position bar
  /// moves, slow enough that a screen left open is not a load on the server.
  static const _pollInterval = Duration(seconds: 5);

  Timer? _poll;
  List<PlaybackSession> _sessions = const [];

  /// Per-server failure text, keyed by server id, so one unreachable server
  /// does not hide the sessions the others reported.
  final Map<String, String> _errors = {};

  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(_pollInterval, (_) => unawaited(_refresh(quiet: true)));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Every server this user administers, paired with its activity client.
  List<({String serverId, String name, MediaServerActivityClient client})> _activityServers() {
    final manager = context.read<MultiServerProvider>().serverManager;
    final servers = <({String serverId, String name, MediaServerActivityClient client})>[];
    for (final entry in manager.onlineClients.entries) {
      final serverId = ServerId(entry.key);
      if (!manager.isOwnerOrAdmin(serverId)) continue;
      // Cast, not promotion: [MediaServerActivityClient] is a sibling
      // interface of [MediaServerClient], not a subtype of it, so an `is`
      // check cannot narrow the variable.
      final client = entry.value;
      if (client is MediaServerActivityClient) {
        servers.add((
          serverId: entry.key,
          name: manager.serverDisplayName(serverId),
          client: client as MediaServerActivityClient,
        ));
      }
    }
    return servers;
  }

  Future<void> _refresh({bool quiet = false}) async {
    final servers = _activityServers();
    if (!quiet) setStateIfMounted(() => _loading = true);

    final collected = <PlaybackSession>[];
    final errors = <String, String>{};
    for (final server in servers) {
      try {
        collected.addAll(await server.client.fetchActiveSessions());
      } catch (e) {
        // Reported per server and kept out of the list, rather than thrown:
        // the common failure is a non-owner token on one of several servers.
        appLogger.w('Could not read sessions from ${server.name}', error: e);
        errors[server.serverId] = t.serverActivity.loadFailed(server: server.name);
      }
    }

    // Stable order so rows do not jump between polls: by user, then by what
    // they are watching.
    collected.sort((a, b) {
      final byUser = (a.userName ?? '').compareTo(b.userName ?? '');
      return byUser != 0 ? byUser : (a.title ?? '').compareTo(b.title ?? '');
    });

    setStateIfMounted(() {
      _sessions = collected;
      _errors
        ..clear()
        ..addAll(errors);
      _loading = false;
    });
  }

  String _methodLabel(StreamMethod method) => switch (method) {
    StreamMethod.directPlay => t.serverActivity.directPlay,
    StreamMethod.directStream => t.serverActivity.directStream,
    StreamMethod.transcode => t.serverActivity.transcoding,
  };

  Future<void> _stop(PlaybackSession session) async {
    final reason = await _promptForText(
      title: t.serverActivity.stopTitle(user: session.userName ?? session.deviceName ?? ''),
      body: t.serverActivity.stopBody,
      // Plex shows the reason itself on termination; Jellyfin only if the
      // client takes a message. Say so rather than offering a field whose text
      // nobody will ever see.
      hint: session.backend == MediaBackend.plex || session.canMessage
          ? t.serverActivity.stopReasonHint
          : t.serverActivity.stopReasonUnsupportedHere,
      confirmLabel: t.serverActivity.stopConfirm,
      // A reason is optional; an empty box still stops the stream.
      allowEmpty: true,
    );
    if (reason == null || !mounted) return;

    final client = _clientFor(session);
    if (client == null) return;
    setStateIfMounted(() => _busy = true);
    try {
      await client.stopSession(session, reason: reason.isEmpty ? null : reason);
      if (mounted) showSuccessSnackBar(context, t.serverActivity.stopped);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, t.serverActivity.stopFailed(error: e.toString()));
    } finally {
      setStateIfMounted(() => _busy = false);
      await _refresh(quiet: true);
    }
  }

  Future<void> _message(PlaybackSession session) async {
    final message = await _promptForText(
      title: t.serverActivity.messageTitle(user: session.userName ?? session.deviceName ?? ''),
      hint: t.serverActivity.messageHint,
      confirmLabel: t.serverActivity.messageSend,
      allowEmpty: false,
    );
    if (message == null || message.isEmpty || !mounted) return;

    final client = _clientFor(session);
    if (client == null) return;
    setStateIfMounted(() => _busy = true);
    try {
      await client.messageSession(session, message: message);
      if (mounted) showSuccessSnackBar(context, t.serverActivity.messageSent);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, t.serverActivity.messageFailed(error: e.toString()));
    } finally {
      setStateIfMounted(() => _busy = false);
    }
  }

  MediaServerActivityClient? _clientFor(PlaybackSession session) {
    final client = context.read<MultiServerProvider>().serverManager.getClient(session.serverId);
    if (client is MediaServerActivityClient) return client as MediaServerActivityClient;
    return null;
  }

  /// One-field prompt shared by stop and message.
  Future<String?> _promptForText({
    required String title,
    String? body,
    required String hint,
    required String confirmLabel,
    required bool allowEmpty,
  }) {
    final controller = TextEditingController();
    return showScopedDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            if (body != null) ...[Text(body), const SizedBox(height: 12)],
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: hint),
              onSubmitted: (value) {
                if (allowEmpty || value.trim().isNotEmpty) Navigator.pop(context, value.trim());
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
          TextButton(
            onPressed: () {
              final value = controller.text.trim();
              if (!allowEmpty && value.isEmpty) return;
              Navigator.pop(context, value);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watched, not read: a server coming online or going away changes whether
    // there is anything to show.
    context.watch<MultiServerProvider>();
    final servers = _activityServers();
    final monoTokens = tokens(context);

    return SettingsPage(
      title: Text(t.serverActivity.title),
      children: [
        SettingsGroup(
          title: t.serverActivity.title,
          children: [
            if (servers.isEmpty)
              ListTile(
                leading: const AppIcon(Symbols.admin_panel_settings_rounded, fill: 1),
                title: Text(t.serverActivity.notAdmin),
              )
            else ...[
              for (final error in _errors.values)
                ListTile(
                  leading: AppIcon(Symbols.error_rounded, fill: 1, color: Theme.of(context).colorScheme.error),
                  title: Text(error),
                ),
              if (_sessions.isEmpty)
                ListTile(
                  leading: AppIcon(_loading ? Symbols.hourglass_top_rounded : Symbols.pause_circle_rounded, fill: 1),
                  title: Text(_loading ? t.common.loading : t.serverActivity.empty),
                )
              else
                for (final session in _sessions) _buildSessionTile(session, monoTokens, servers.length > 1),
              ListTile(
                leading: const AppIcon(Symbols.refresh_rounded, fill: 1),
                title: Text(t.serverActivity.refresh),
                enabled: !_busy,
                onTap: _busy ? null : () => unawaited(_refresh()),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildSessionTile(PlaybackSession session, MonoTokens monoTokens, bool showServerName) {
    final manager = context.read<MultiServerProvider>().serverManager;
    final episodeLabel = formatSeasonEpisodeLabel(session.seasonIndex, session.episodeIndex);

    final heading = [?session.subtitle, ?episodeLabel, ?session.title].join(' · ');

    final who = [
      ?session.userName,
      ?session.deviceName,
      if (session.clientName != null && session.clientName != session.deviceName) session.clientName!,
    ].join(' · ');

    // Transcode detail per track, because a mixed session is the common one
    // and "transcoding" alone does not say which half costs the CPU.
    final streams = <String>[
      if (session.video != null) '${t.serverActivity.videoLabel} ${_methodLabel(session.video!.method)}',
      if (session.audio != null) '${t.serverActivity.audioLabel} ${_methodLabel(session.audio!.method)}',
    ].join(' · ');

    final position = session.positionMs;
    final duration = session.durationMs;
    final progressText = position == null
        ? null
        : duration == null
        ? formatDurationTimestamp(Duration(milliseconds: position))
        : '${formatDurationTimestamp(Duration(milliseconds: position))}'
              ' / ${formatDurationTimestamp(Duration(milliseconds: duration))}';

    final lines = <String>[
      if (who.isNotEmpty) who,
      [if (session.isPaused) t.serverActivity.paused, ?progressText, if (streams.isNotEmpty) streams].join(' · '),
      [
        ?session.transcodeReason,
        if (session.bandwidthKbps != null) t.serverActivity.bandwidth(kbps: '${session.bandwidthKbps}'),
        if (session.isRemote == true) t.serverActivity.remote,
        if (showServerName) manager.serverDisplayName(session.serverId),
      ].join(' · '),
    ].where((line) => line.isNotEmpty).toList();

    return ListTile(
      leading: AppIcon(
        session.isPaused ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
        fill: 1,
        color: session.effectiveMethod == StreamMethod.transcode ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(heading.isEmpty ? session.sessionId : heading),
      subtitle: Text(lines.join('\n'), style: TextStyle(color: monoTokens.textMuted, fontSize: 12)),
      isThreeLine: lines.length > 1,
      trailing: Row(
        mainAxisSize: .min,
        children: [
          if (session.canMessage)
            IconButton(
              icon: const AppIcon(Symbols.chat_rounded, fill: 1),
              tooltip: t.serverActivity.message,
              onPressed: _busy ? null : () => unawaited(_message(session)),
            ),
          IconButton(
            icon: const AppIcon(Symbols.stop_circle_rounded, fill: 1),
            tooltip: session.canStop ? t.serverActivity.stop : t.serverActivity.stopUnsupported,
            onPressed: _busy || !session.canStop ? null : () => unawaited(_stop(session)),
          ),
        ],
      ),
    );
  }
}
