import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../mixins/mounted_set_state_mixin.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/server_health.dart';
import '../../theme/mono_tokens.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';

/// Shows which endpoint each server is on and how it is answering.
///
/// The app already races endpoints, escapes relays, fails over and demotes;
/// none of it was visible. Poor playback and a server that reads "online" look
/// identical from the outside, and the usual cause — the stream going through
/// Plex's relay, capped around 2 Mbps — is exactly the thing the app knew and
/// did not say.
class ServerHealthScreen extends StatefulWidget {
  const ServerHealthScreen({super.key});

  @override
  State<ServerHealthScreen> createState() => _ServerHealthScreenState();
}

class _ServerHealthScreenState extends State<ServerHealthScreen> with MountedSetStateMixin {
  /// Measured round trips, by server id. Kept here rather than in the manager:
  /// a latency is a reading someone asked for, not server state.
  final Map<String, Duration?> _latencies = {};
  final Set<String> _measuring = {};
  bool _reRacing = false;

  Future<void> _measure(String serverId) async {
    if (_measuring.contains(serverId)) return;
    setStateIfMounted(() => _measuring.add(serverId));
    final manager = context.read<MultiServerProvider>().serverManager;
    final latency = await manager.measureServerLatency(ServerId(serverId));
    setStateIfMounted(() {
      _measuring.remove(serverId);
      _latencies[serverId] = latency;
    });
  }

  Future<void> _reRace() async {
    if (_reRacing) return;
    setStateIfMounted(() => _reRacing = true);
    final manager = context.read<MultiServerProvider>().serverManager;
    try {
      // The same three steps the app runs on resume: find out what is actually
      // up, reconnect what is not, then re-race anything sitting on a worse
      // endpoint than it could have.
      await manager.checkServerHealth();
      await manager.reconnectOfflineServers();
      await manager.reoptimizeDemotedServers(reason: 'server health screen');
    } finally {
      setStateIfMounted(() => _reRacing = false);
    }
  }

  String _linkLabel(ServerLinkKind link) => switch (link) {
    ServerLinkKind.local => t.serverHealth.linkLocal,
    ServerLinkKind.remote => t.serverHealth.linkRemote,
    ServerLinkKind.relay => t.serverHealth.linkRelay,
    ServerLinkKind.unknown => t.serverHealth.linkUnknown,
  };

  IconData _linkIcon(ServerLinkKind link) => switch (link) {
    ServerLinkKind.local => Symbols.home_rounded,
    ServerLinkKind.remote => Symbols.public_rounded,
    ServerLinkKind.relay => Symbols.cell_tower_rounded,
    ServerLinkKind.unknown => Symbols.help_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MultiServerProvider>();
    final servers = provider.serverManager.describeServerHealth();
    final monoTokens = tokens(context);

    return SettingsPage(
      title: Text(t.serverHealth.title),
      children: [
        SettingsGroup(
          title: t.serverHealth.title,
          children: [
            if (servers.isEmpty)
              ListTile(leading: const AppIcon(Symbols.dns_rounded, fill: 1), title: Text(t.serverHealth.empty))
            else
              for (final server in servers) _buildServerTile(server, monoTokens),
            ListTile(
              leading: const AppIcon(Symbols.refresh_rounded, fill: 1),
              title: Text(_reRacing ? t.serverHealth.reRaceRunning : t.serverHealth.reRace),
              subtitle: Text(t.serverHealth.subtitle),
              enabled: !_reRacing,
              onTap: _reRacing ? null : () => _reRace(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildServerTile(ServerHealth server, MonoTokens monoTokens) {
    final status = switch (true) {
      _ when server.authError => t.serverHealth.statusAuthError,
      _ when !server.visible => t.serverHealth.statusHidden,
      _ when !server.online => t.serverHealth.statusOffline,
      _ => t.serverHealth.statusOnline,
    };

    final latency = _latencies[server.serverId];
    final measured = _latencies.containsKey(server.serverId);
    final lines = <String>[
      '${_linkLabel(server.link)} · $status',
      if (server.endpoint != null) server.endpoint!,
      if (server.link == ServerLinkKind.relay) t.serverHealth.linkRelayWarning,
      if (server.relayEscapePending) t.serverHealth.relayEscapePending,
      if (_measuring.contains(server.serverId))
        t.serverHealth.measure
      else if (measured)
        latency == null ? t.serverHealth.latencyFailed : t.serverHealth.latency(ms: latency.inMilliseconds.toString()),
    ];

    return ListTile(
      leading: AppIcon(
        _linkIcon(server.link),
        fill: 1,
        color: server.needsAttention ? Theme.of(context).colorScheme.error : null,
      ),
      title: Text(server.name),
      subtitle: Text(lines.join('\n'), style: TextStyle(color: monoTokens.textMuted, fontSize: 12)),
      isThreeLine: true,
      trailing: IconButton(
        icon: const AppIcon(Symbols.network_ping_rounded, fill: 1),
        tooltip: t.serverHealth.measure,
        onPressed: _measuring.contains(server.serverId) ? null : () => _measure(server.serverId),
      ),
    );
  }
}
