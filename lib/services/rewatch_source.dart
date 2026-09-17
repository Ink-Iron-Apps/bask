import '../media/library_query.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../media/media_server_client.dart';
import '../utils/app_logger.dart';
import 'rewatch_service.dart';

/// Fetches what [RewatchService] reasons over.
///
/// Kept apart from the rules so the rules stay testable without a server, and
/// so the cost of this — one library query per TV library, then one episode
/// list per show on the rail — is visible in one place rather than spread
/// through a provider.
class RewatchSource {
  const RewatchSource({this.recentEpisodeLimit = 40, this.maxEntries = 8});

  /// How many recently played episodes to consider per library.
  ///
  /// Only the newest episode of each show survives grouping, so this is a
  /// ceiling on shows-in-flight rather than on episodes: forty covers a
  /// plausible spread of concurrent rewatches without asking a server for a
  /// library's whole history.
  final int recentEpisodeLimit;

  final int maxEntries;

  /// Recently played episodes across every show library the client serves.
  Future<List<MediaItem>> recentlyWatched(MediaServerClient client, List<MediaLibrary> libraries) async {
    final showLibraries = libraries.where((library) => library.kind == MediaKind.show);
    final episodes = <MediaItem>[];

    for (final library in showLibraries) {
      try {
        final page = await client.fetchLibraryPagedContent(
          library.id,
          query: LibraryQuery(
            kind: MediaKind.episode,
            // The whole point: what this user played most recently, watched
            // or not. The server scopes it to the token's account, which is
            // what makes the rail per-user and identical on every device.
            sort: const LibrarySort(field: 'lastViewedAt'),
            limit: recentEpisodeLimit,
          ),
          libraryKind: MediaKind.show,
        );
        episodes.addAll(page.items);
      } catch (e) {
        // A library that will not answer costs its own rows, not the rail.
        appLogger.d('Rewatch: could not read recent episodes from ${library.title}', error: e);
      }
    }

    return episodes;
  }

  /// The rail for one client.
  ///
  /// [alreadyOffered] should carry the show keys the server's own Continue
  /// Watching covers, so the two rails never name the same show.
  Future<List<RewatchEntry>> build(
    MediaServerClient client,
    List<MediaLibrary> libraries, {
    Set<String> alreadyOffered = const {},
  }) async {
    final recent = await recentlyWatched(client, libraries);
    if (recent.isEmpty) return const [];

    return RewatchService.build(
      recentlyWatched: recent,
      alreadyOffered: alreadyOffered,
      maxEntries: maxEntries,
      episodesForShow: (lastWatched) async =>
          await client.fetchClientSideEpisodeQueue(lastWatched.grandparentId!) ?? const [],
    );
  }
}
