import 'package:bask/connection/connection.dart';
import 'package:bask/connection/connection_registry.dart';
import 'package:bask/database/app_database.dart';
import 'package:bask/profiles/active_plex_identity.dart';
import 'package:bask/profiles/active_profile_provider.dart';
import 'package:bask/profiles/plex_home_service.dart';
import 'package:bask/profiles/profile.dart';
import 'package:bask/profiles/profile_connection.dart';
import 'package:bask/profiles/profile_connection_registry.dart';
import 'package:bask/profiles/profile_registry.dart';
import 'package:bask/services/plex_auth_service.dart';
import 'package:bask/services/storage_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_helpers/prefs.dart';

/// Every caller of this resolves a credential to send to plex.tv -- Discover,
/// Seerr, the companion remote. A direct server's token belongs to that one
/// server, so a row that offered one here would leak the credential to a
/// service with no business holding it.
void main() {
  late AppDatabase db;
  late ConnectionRegistry connections;
  late ProfileConnectionRegistry profileConnections;
  late ProfileRegistry profiles;
  late PlexHomeService plexHome;
  late ActiveProfileProvider activeProfile;
  late StorageService storage;

  setUp(() async {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    connections = ConnectionRegistry(db);
    profileConnections = ProfileConnectionRegistry(db);
    profiles = ProfileRegistry(db);
    storage = await StorageService.getInstance();
    plexHome = PlexHomeService(
      connections: connections,
      profileConnections: profileConnections,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    activeProfile = ActiveProfileProvider(
      registry: profiles,
      plexHome: plexHome,
      connections: connections,
      profileConnections: profileConnections,
      storage: storage,
    );
  });

  tearDown(() async {
    await activeProfile.resetForTesting();
    activeProfile.dispose();
    await plexHome.dispose();
    await db.close();
  });

  PlexServer server() => PlexServer(
    name: 'Home Server',
    clientIdentifier: 'srv-1',
    accessToken: 'server-token',
    connections: [
      PlexConnection(
        protocol: 'https',
        address: '192.168.1.3',
        port: 32400,
        uri: 'https://192.168.1.3:32400',
        local: true,
        relay: false,
        ipv6: false,
      ),
    ],
    owned: true,
  );

  PlexAccountConnection account({required String id, required bool direct}) => PlexAccountConnection(
    id: id,
    accountToken: 'token-for-$id',
    clientIdentifier: 'client-id',
    accountLabel: id,
    servers: [server()],
    direct: direct,
    createdAt: DateTime(2026, 1, 1),
  );

  Future<Profile> activeProfileBoundTo(PlexAccountConnection connection, {String id = 'local-owner'}) async {
    final profile = Profile.local(id: id, displayName: 'Owner', createdAt: DateTime(2026, 1, 1));
    await profiles.upsert(profile);
    await profileConnections.upsert(
      ProfileConnection(
        profileId: profile.id,
        connectionId: connection.id,
        userToken: connection.accountToken,
        userIdentifier: 'srv-1',
      ),
    );
    await storage.setActiveProfileId(profile.id);
    await activeProfile.initialize();
    return profile;
  }

  Future<ActivePlexIdentity?> resolve() => resolveActivePlexIdentity(
    activeProfile: activeProfile,
    connections: connections,
    profileConnections: profileConnections,
  );

  test('a plex.tv account resolves as it always did', () async {
    final plex = account(id: 'plex.account', direct: false);
    await connections.upsert(plex);
    await activeProfileBoundTo(plex);

    expect((await resolve())?.account.id, 'plex.account');
  });

  test('a profile whose only connection is a direct server resolves to nothing', () async {
    final direct = account(id: 'direct.bms-1', direct: true);
    await connections.upsert(direct);
    await activeProfileBoundTo(direct);

    expect(await resolve(), isNull);
  });

  test('a direct server alongside a plex.tv account never stands in for it', () async {
    final direct = account(id: 'direct.bms-1', direct: true);
    final plex = account(id: 'plex.account', direct: false);
    // The direct row is inserted first, so a resolver that took whichever it
    // met first would pick it.
    await connections.upsert(direct);
    await connections.upsert(plex);
    final profile = Profile.local(id: 'local-owner', displayName: 'Owner', createdAt: DateTime(2026, 1, 1));
    await profiles.upsert(profile);
    for (final connection in [direct, plex]) {
      await profileConnections.upsert(
        ProfileConnection(
          profileId: profile.id,
          connectionId: connection.id,
          userToken: connection.accountToken,
          userIdentifier: 'srv-1',
        ),
      );
    }
    await storage.setActiveProfileId(profile.id);
    await activeProfile.initialize();

    expect((await resolve())?.account.id, 'plex.account');
  });

  test('a direct server is not the fallback when no profile is active', () async {
    await connections.upsert(account(id: 'direct.bms-1', direct: true));
    await activeProfile.initialize();

    expect(await resolve(), isNull);
  });
}
