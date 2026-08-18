import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../connection/connection.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../services/plex_auth_service.dart';
import '../../services/storage_service.dart';
import '../../media/ids.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';

/// Lets the user pin addresses for the servers on a Plex account.
///
/// plex.tv only advertises endpoints it can reach from the public internet, so
/// an address that lives on a VPN, behind split-horizon DNS or on an internal
/// reverse proxy never appears in the discovered list — no matter how the
/// server itself is configured. This is the only way such an address reaches
/// the failover chain.
class EditPlexEndpointsScreen extends StatefulWidget {
  final PlexAccountConnection connection;

  const EditPlexEndpointsScreen({super.key, required this.connection});

  @override
  State<EditPlexEndpointsScreen> createState() => _EditPlexEndpointsScreenState();
}

class _EditPlexEndpointsScreenState extends State<EditPlexEndpointsScreen>
    with AsyncFormStateMixin, ControllerDisposerMixin {
  final _formKey = GlobalKey<FormState>();
  final _saveFocus = FocusNode(debugLabel: 'EditPlexEndpoints:Save');
  final _controllers = <String, TextEditingController>{};
  final _focusNodes = <String, FocusNode>{};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaitedLoad();
  }

  void unawaitedLoad() {
    () async {
      final storage = await StorageService.getInstance();
      if (!mounted) return;
      for (final server in widget.connection.servers) {
        final id = server.clientIdentifier;
        final saved = storage.getServerCustomEndpoints(ServerId(id));
        _controllers[id] = createTextEditingController(text: saved.join('\n'));
        _focusNodes[id] = FocusNode(debugLabel: 'EditPlexEndpoints:$id');
      }
      setState(() => _loaded = true);
    }();
  }

  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _saveFocus.dispose();
    super.dispose();
  }

  List<String> _entered(String serverId) => (_controllers[serverId]?.text ?? '')
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await runAsync<void>(() async {
      final storage = await StorageService.getInstance();
      for (final server in widget.connection.servers) {
        final id = server.clientIdentifier;
        await storage.saveServerCustomEndpoints(ServerId(id), _entered(id));
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.profiles.plexEndpoints.title),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: !_loaded
                ? const Center(child: LoadingIndicatorBox())
                : Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(t.profiles.plexEndpoints.explanation, style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 8),
                        Text(
                          t.profiles.plexEndpoints.order,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 24),
                        for (final server in widget.connection.servers) ...[
                          _serverField(server, theme),
                          const SizedBox(height: 24),
                        ],
                        FocusableButton(
                          focusNode: _saveFocus,
                          useBackgroundFocus: true,
                          onPressed: busy ? null : _save,
                          child: FilledButton.icon(
                            onPressed: busy ? null : _save,
                            icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.save_rounded, fill: 1),
                            label: Text(t.common.save),
                          ),
                        ),
                        ...buildInlineError(theme),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _serverField(PlexServer server, ThemeData theme) {
    final advertised = server.connections.map((c) => c.uri).toSet().toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(server.name, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          advertised.isEmpty
              ? t.profiles.plexEndpoints.advertisedNone
              : t.profiles.plexEndpoints.advertised(addresses: advertised.join(', ')),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        FocusableTextFormField(
          controller: _controllers[server.clientIdentifier]!,
          focusNode: _focusNodes[server.clientIdentifier]!,
          tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
          keyboardType: TextInputType.url,
          minLines: 1,
          maxLines: 4,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !busy,
          onNavigateDown: () => _saveFocus.requestFocus(),
          decoration: InputDecoration(
            labelText: t.profiles.plexEndpoints.fieldLabel,
            hintText: t.profiles.plexEndpoints.fieldHint,
            prefixIcon: const AppIcon(Symbols.vpn_lock_rounded, fill: 1),
          ),
          validator: (_) => _entered(server.clientIdentifier).every(PlexServer.isValidCustomEndpoint)
              ? null
              : t.profiles.plexEndpoints.invalid,
        ),
      ],
    );
  }
}
