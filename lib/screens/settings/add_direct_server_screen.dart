import 'package:flutter/material.dart';
import 'package:bask/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../connection/bask_server_setup.dart';
import '../../connection/connection.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_connection.dart';
import '../../services/storage_service.dart';
import '../../utils/app_logger.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../profile/profile_switch_screen.dart';
import 'async_form_state_mixin.dart';
import 'connection_persistence.dart';

/// Add a server that speaks the Plex dialect but is not a Plex account —
/// Bask Media Server, which issues its own tokens.
///
/// Two fields and one button, because there is nothing to discover: the person
/// adding it runs the server, so they have the address and can read a token
/// out of its admin pages. The flow probes the address unauthenticated first
/// so a wrong address and a wrong token are reported as the different mistakes
/// they are, then persists through the same path the MediaBrowser form uses.
class AddDirectServerScreen extends StatefulWidget {
  /// When set, the new connection is bound to this profile. When null it binds
  /// to the active profile, which is how the global Connections screen enters.
  final Profile? targetProfile;

  /// Test seam: the setup that does the probing.
  final BaskServerSetup Function()? setupFactory;

  const AddDirectServerScreen({super.key, this.targetProfile, @visibleForTesting this.setupFactory});

  @override
  State<AddDirectServerScreen> createState() => _AddDirectServerScreenState();
}

class _AddDirectServerScreenState extends State<AddDirectServerScreen>
    with AsyncFormStateMixin, ControllerDisposerMixin {
  final _formKey = GlobalKey<FormState>();
  late final _urlController = createTextEditingController();
  late final _tokenController = createTextEditingController();
  final _urlFocus = FocusNode(debugLabel: 'AddDirectServer:Url');
  final _tokenFocus = FocusNode(debugLabel: 'AddDirectServer:Token');
  final _connectFocus = FocusNode(debugLabel: 'AddDirectServer:Connect');

  @override
  void dispose() {
    _urlFocus.dispose();
    _tokenFocus.dispose();
    _connectFocus.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    final storage = context.read<StorageService>();

    final connection = await runAsync<PlexAccountConnection>(
      () async {
        final setup = widget.setupFactory?.call() ?? BaskServerSetup();
        return setup.build(baseUrl: url, token: token, clientIdentifier: await storage.getOrCreateClientIdentifier());
      },
      errorMapper: (error) {
        appLogger.w('Could not add a direct server', error: error);
        // The setup raises display text for everything it can name; anything
        // else is a bug and reads better as the transport failure it is than
        // as a Dart exception.
        if (error is MediaServerException && error.display != null) return error.display!;
        return t.addServer.couldNotReachServer(error: error);
      },
    );
    if (connection == null || !mounted) return;
    await _persistAndExit(connection);
  }

  /// Provision the connection and its ownership row, then pop.
  ///
  /// The profile rules are the MediaBrowser ones, for the same reasons: a
  /// server binds to one profile, a first run has no profile to bind to yet,
  /// and an install with several needs the person to say which.
  Future<void> _persistAndExit(PlexAccountConnection connection) async {
    final activeProvider = context.read<ActiveProfileProvider>();
    await activeProvider.initialize();
    if (!mounted) return;

    final targetProfile = widget.targetProfile;
    var boundProfile = targetProfile ?? activeProvider.active;
    if (targetProfile == null && activeProvider.active == null && activeProvider.profiles.isNotEmpty) {
      await Navigator.of(
        context,
        rootNavigator: true,
      ).push<bool>(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen(requireSelection: true)));
      if (!mounted) return;
      boundProfile = activeProvider.active;
    }

    Profile? firstRunProfile;
    if (targetProfile == null && boundProfile == null && activeProvider.profiles.isEmpty) {
      final now = DateTime.now();
      firstRunProfile = Profile.local(
        id: 'local-${const Uuid().v4()}',
        displayName: connection.accountLabel,
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
      );
      boundProfile = firstRunProfile;
    }

    final bindProfile = boundProfile;
    if (bindProfile == null) {
      setErrorText(t.messages.noProfilesAvailable);
      return;
    }

    await persistAndBindConnection(
      context: context,
      connection: connection,
      bindToProfile: ProfileConnection(
        profileId: bindProfile.id,
        connectionId: connection.id,
        // The server's own token is the credential, and there is no plex.tv
        // `/switch` that could mint a replacement, so it is stored here rather
        // than left as the lazy-fetch sentinel a Plex account uses.
        userToken: connection.accountToken,
        userIdentifier: connection.servers.first.clientIdentifier,
        tokenAcquiredAt: DateTime.now(),
      ),
      firstRunProfile: firstRunProfile,
    );

    final boundToActive = bindProfile.id == activeProvider.activeId;
    if (!mounted) return;
    if (boundToActive) {
      await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.addServer.addDirectServerTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: .stretch,
                children: [
                  FocusableTextFormField(
                    controller: _urlController,
                    focusNode: _urlFocus,
                    // Logically single-line URL input, which every TV's own
                    // keyboard handles better than the Flutter overlay.
                    tvTextInputPresentation: TvTextInputPresentation.platform,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    onNavigateDown: () => _tokenFocus.requestFocus(),
                    onFieldSubmitted: busy ? null : (_) => _tokenFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: t.addServer.serverUrl,
                      // An address example, deliberately not localized.
                      hintText: 'http://192.168.1.10:32400',
                      helperText: t.addServer.serverUrlHelper,
                      prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
                    ),
                    // The same parser the candidate list is built with, so a
                    // value the form accepts is one the client can reach.
                    validator: (value) {
                      final raw = value?.trim() ?? '';
                      if (raw.isEmpty) return t.addServer.required;
                      return BaskServerSetup.isValidUrl(raw) ? null : t.addServer.enterDirectServerUrl;
                    },
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _tokenController,
                    focusNode: _tokenFocus,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.go,
                    onNavigateUp: () => _urlFocus.requestFocus(),
                    onNavigateDown: () => _connectFocus.requestFocus(),
                    onFieldSubmitted: busy ? null : (_) => _connect(),
                    decoration: InputDecoration(
                      labelText: t.addServer.serverToken,
                      helperText: t.addServer.serverTokenHelper,
                      prefixIcon: const AppIcon(Symbols.key_rounded, fill: 1),
                    ),
                    validator: (value) => (value?.trim().isEmpty ?? true) ? t.addServer.enterServerToken : null,
                  ),
                  const SizedBox(height: 16),
                  FocusableButton(
                    focusNode: _connectFocus,
                    useBackgroundFocus: true,
                    onNavigateUp: () => _tokenFocus.requestFocus(),
                    onPressed: busy ? null : _connect,
                    child: FilledButton.icon(
                      onPressed: busy ? null : _connect,
                      icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.dns_rounded, fill: 1),
                      label: Text(t.addServer.connect),
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
}
