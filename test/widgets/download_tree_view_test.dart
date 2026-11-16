import 'package:flutter_test/flutter_test.dart';
import 'package:bask/media/ids.dart';
import 'package:bask/media/media_backend.dart';
import 'package:bask/media/media_item.dart';
import 'package:bask/media/media_kind.dart';
import 'package:bask/models/download_models.dart';
import 'package:bask/widgets/download_tree_view.dart';
import '../test_helpers/media_items.dart';

DownloadTreeNode _episodeNode(String globalKey) => DownloadTreeNode(
  key: globalKey,
  title: 'Episode',
  type: DownloadNodeType.episode,
  status: DownloadStatus.completed,
);

DownloadTreeNode _seasonNode({required String key, required List<DownloadTreeNode> children}) => DownloadTreeNode(
  key: key,
  title: 'Season',
  type: DownloadNodeType.season,
  status: DownloadStatus.completed,
  children: children,
);

DownloadTreeNode _showNode({required String key, required List<DownloadTreeNode> children}) => DownloadTreeNode(
  key: key,
  title: 'Show',
  type: DownloadNodeType.show,
  status: DownloadStatus.completed,
  children: children,
);

MediaItem _episodeMeta({
  required String id,
  required ServerId? serverId,
  required String? grandparentId,
  required String? parentId,
}) => testMediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  title: 'Ep $id',
  serverId: serverId,
  grandparentId: grandparentId,
  parentId: parentId,
);

void main() {
  group('buildDownloadTree ordering', () {
    MediaItem movieMeta(String id, String title) => testMediaItem(
      id: id,
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: title,
      serverId: ServerId('plex1'),
    );

    DownloadProgress progress(String globalKey, DownloadStatus status) =>
        DownloadProgress(globalKey: globalKey, status: status);

    test('a downloading show outranks a completed movie', () {
      // Categories used to be concatenated movies-then-shows, so a show being
      // downloaded right now sank below every finished movie.
      final downloads = {
        'plex1:movie1': progress('plex1:movie1', DownloadStatus.completed),
        'plex1:ep1': progress('plex1:ep1', DownloadStatus.downloading),
      };
      final metadata = {
        'plex1:movie1': movieMeta('movie1', 'Finished Movie'),
        'plex1:ep1': _episodeMeta(id: 'ep1', serverId: ServerId('plex1'), grandparentId: '42', parentId: '7'),
      };

      final tree = buildDownloadTree(downloads: downloads, metadata: metadata);

      expect(tree.first.type, DownloadNodeType.show);
      expect(tree.first.status, DownloadStatus.downloading);
    });

    test('queued and paused items also sort above completed ones', () {
      final downloads = {
        'plex1:movie1': progress('plex1:movie1', DownloadStatus.completed),
        'plex1:movie2': progress('plex1:movie2', DownloadStatus.queued),
        'plex1:movie3': progress('plex1:movie3', DownloadStatus.paused),
        'plex1:movie4': progress('plex1:movie4', DownloadStatus.downloading),
      };
      final metadata = {
        'plex1:movie1': movieMeta('movie1', 'A Completed'),
        'plex1:movie2': movieMeta('movie2', 'B Queued'),
        'plex1:movie3': movieMeta('movie3', 'C Paused'),
        'plex1:movie4': movieMeta('movie4', 'D Downloading'),
      };

      final tree = buildDownloadTree(downloads: downloads, metadata: metadata);

      expect(tree.map((n) => n.status).take(3), [
        DownloadStatus.downloading,
        DownloadStatus.queued,
        DownloadStatus.paused,
      ]);
      expect(tree.last.status, DownloadStatus.completed);
    });

    test('a failed item stays below active work', () {
      final downloads = {
        'plex1:movie1': progress('plex1:movie1', DownloadStatus.failed),
        'plex1:movie2': progress('plex1:movie2', DownloadStatus.queued),
      };
      final metadata = {
        'plex1:movie1': movieMeta('movie1', 'A Failed'),
        'plex1:movie2': movieMeta('movie2', 'B Queued'),
      };

      final tree = buildDownloadTree(downloads: downloads, metadata: metadata);

      expect(tree.first.status, DownloadStatus.queued);
      expect(tree.last.status, DownloadStatus.failed);
    });
  });

  group('buildDownloadTree playlist grouping', () {
    MediaItem movieMeta(String id, String title) => testMediaItem(
      id: id,
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: title,
      serverId: ServerId('plex1'),
    );

    DownloadProgress progress(String globalKey, DownloadStatus status) =>
        DownloadProgress(globalKey: globalKey, status: status);

    test('a playlist collects its members under one collapsible node', () {
      final downloads = {
        'plex1:m1': progress('plex1:m1', DownloadStatus.completed),
        'plex1:m2': progress('plex1:m2', DownloadStatus.completed),
      };
      final metadata = {'plex1:m1': movieMeta('m1', 'First'), 'plex1:m2': movieMeta('m2', 'Second')};

      final tree = buildDownloadTree(
        downloads: downloads,
        metadata: metadata,
        playlists: [
          DownloadPlaylistGroup(key: 'plex1:pl9', title: 'Road Trip', memberKeys: {'plex1:m1', 'plex1:m2'}),
        ],
      );

      expect(tree, hasLength(1));
      expect(tree.single.type, DownloadNodeType.playlist);
      expect(tree.single.title, 'Road Trip');
      expect(tree.single.children.map((c) => c.key), containsAll(['plex1:m1', 'plex1:m2']));
    });

    test('items outside the playlist keep their own grouping', () {
      final downloads = {
        'plex1:m1': progress('plex1:m1', DownloadStatus.completed),
        'plex1:m2': progress('plex1:m2', DownloadStatus.completed),
      };
      final metadata = {'plex1:m1': movieMeta('m1', 'In List'), 'plex1:m2': movieMeta('m2', 'Standalone')};

      final tree = buildDownloadTree(
        downloads: downloads,
        metadata: metadata,
        playlists: [
          DownloadPlaylistGroup(key: 'plex1:pl9', title: 'Road Trip', memberKeys: {'plex1:m1'}),
        ],
      );

      expect(tree.where((n) => n.type == DownloadNodeType.playlist), hasLength(1));
      expect(tree.where((n) => n.type == DownloadNodeType.movie).map((n) => n.title), ['Standalone']);
    });

    test('an empty playlist contributes no node', () {
      final downloads = {'plex1:m1': progress('plex1:m1', DownloadStatus.completed)};
      final metadata = {'plex1:m1': movieMeta('m1', 'Standalone')};

      final tree = buildDownloadTree(
        downloads: downloads,
        metadata: metadata,
        playlists: [
          DownloadPlaylistGroup(key: 'plex1:pl9', title: 'Empty', memberKeys: {'plex1:missing'}),
        ],
      );

      expect(tree.where((n) => n.type == DownloadNodeType.playlist), isEmpty);
    });

    test('a downloading playlist floats above completed work', () {
      final downloads = {
        'plex1:m1': progress('plex1:m1', DownloadStatus.completed),
        'plex1:m2': progress('plex1:m2', DownloadStatus.downloading),
      };
      final metadata = {'plex1:m1': movieMeta('m1', 'Done'), 'plex1:m2': movieMeta('m2', 'Busy')};

      final tree = buildDownloadTree(
        downloads: downloads,
        metadata: metadata,
        playlists: [
          DownloadPlaylistGroup(key: 'plex1:pl9', title: 'Road Trip', memberKeys: {'plex1:m2'}),
        ],
      );

      expect(tree.first.type, DownloadNodeType.playlist);
      expect(tree.first.status, DownloadStatus.downloading);
    });
  });

  group('container item counts', () {
    DownloadTreeNode ep(String key, DownloadStatus status) =>
        DownloadTreeNode(key: key, title: key, type: DownloadNodeType.episode, status: status);

    test('a show counts episodes, not seasons', () {
      // Ted Lasso reported "0/4" — its season count — while 36 episodes were
      // queued underneath.
      final show = _showNode(
        key: 'show1',
        children: [
          _seasonNode(key: 's1', children: [ep('e1', DownloadStatus.queued), ep('e2', DownloadStatus.completed)]),
          _seasonNode(key: 's2', children: [ep('e3', DownloadStatus.queued)]),
        ],
      );

      expect(show.leafCount, 3);
      expect(show.completedLeafCount, 1);
    });

    test('a season still counts its own episodes', () {
      final season = _seasonNode(
        key: 's1',
        children: [ep('e1', DownloadStatus.completed), ep('e2', DownloadStatus.completed)],
      );

      expect(season.leafCount, 2);
      expect(season.completedLeafCount, 2);
    });

    test('a leaf counts as one', () {
      expect(ep('e1', DownloadStatus.completed).leafCount, 1);
      expect(ep('e1', DownloadStatus.completed).completedLeafCount, 1);
      expect(ep('e1', DownloadStatus.queued).completedLeafCount, 0);
    });
  });

  group('container retry-all visibility', () {
    DownloadTreeNode leaf(String key, DownloadStatus status) =>
        DownloadTreeNode(key: key, title: key, type: DownloadNodeType.episode, status: status);

    test('a container reports a failed leaf even while it is still downloading', () {
      // The aggregate status shows the most pressing state, so a container that
      // is still working reports "downloading" and would hide its failures if
      // the retry-all button keyed off status.
      final season = _seasonNode(
        key: 'show42:season7',
        children: [leaf('ep1', DownloadStatus.downloading), leaf('ep2', DownloadStatus.failed)],
      );

      expect(hasFailedLeaf(season), isTrue);
    });

    test('a container with nothing failed reports none', () {
      final season = _seasonNode(
        key: 'show42:season7',
        children: [leaf('ep1', DownloadStatus.completed), leaf('ep2', DownloadStatus.downloading)],
      );

      expect(hasFailedLeaf(season), isFalse);
    });

    test('a failure nested two levels down still counts', () {
      final season = _seasonNode(key: 'show42:season7', children: [leaf('ep1', DownloadStatus.failed)]);
      final show = _showNode(key: 'show42', children: [season]);

      expect(hasFailedLeaf(show), isTrue);
    });
  });

  group('resolveDownloadContainerGlobalKey', () {
    test('show node: builds globalKey from leaf serverId + grandparentId', () {
      final ep = _episodeNode('plex1:ep100');
      final season = _seasonNode(key: 'show42:season7', children: [ep]);
      final show = _showNode(key: 'show42', children: [season]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: '7'),
      };

      expect(resolveDownloadContainerGlobalKey(show, metadata), 'plex1:42');
    });

    test('season node: builds globalKey from leaf serverId + parentId', () {
      final ep = _episodeNode('plex1:ep100');
      final season = _seasonNode(key: 'show42:season7', children: [ep]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: '7'),
      };

      expect(resolveDownloadContainerGlobalKey(season, metadata), 'plex1:7');
    });

    test('episode and movie nodes return null (not container types)', () {
      final ep = _episodeNode('plex1:ep100');
      final movie = DownloadTreeNode(
        key: 'plex1:movie5',
        title: 'M',
        type: DownloadNodeType.movie,
        status: DownloadStatus.completed,
      );
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: '7'),
      };

      expect(resolveDownloadContainerGlobalKey(ep, metadata), isNull);
      expect(resolveDownloadContainerGlobalKey(movie, metadata), isNull);
    });

    test('container with no leaves returns null', () {
      final empty = _showNode(key: 'show42', children: []);
      expect(resolveDownloadContainerGlobalKey(empty, {}), isNull);
    });

    test('leaf metadata missing in map returns null', () {
      final ep = _episodeNode('plex1:ep100');
      final show = _showNode(key: 'show42', children: [ep]);
      expect(resolveDownloadContainerGlobalKey(show, const {}), isNull);
    });

    test('leaf metadata missing serverId returns null', () {
      final ep = _episodeNode('plex1:ep100');
      final show = _showNode(key: 'show42', children: [ep]);
      final metadata = {'plex1:ep100': _episodeMeta(id: '100', serverId: null, grandparentId: '42', parentId: '7')};
      expect(resolveDownloadContainerGlobalKey(show, metadata), isNull);
    });

    test('show node with leaf missing grandparentId returns null', () {
      final ep = _episodeNode('plex1:ep100');
      final show = _showNode(key: 'show42', children: [ep]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: null, parentId: '7'),
      };
      expect(resolveDownloadContainerGlobalKey(show, metadata), isNull);
    });

    test('season node with leaf missing parentId returns null', () {
      final ep = _episodeNode('plex1:ep100');
      final season = _seasonNode(key: 'show42:season7', children: [ep]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: null),
      };
      expect(resolveDownloadContainerGlobalKey(season, metadata), isNull);
    });

    test('walks nested season for first leaf when show has multiple seasons', () {
      final ep1 = _episodeNode('plex1:ep100');
      final ep2 = _episodeNode('plex1:ep200');
      final s1 = _seasonNode(key: 'show42:season1', children: [ep1]);
      final s2 = _seasonNode(key: 'show42:season2', children: [ep2]);
      final show = _showNode(key: 'show42', children: [s1, s2]);
      final metadata = {
        'plex1:ep100': _episodeMeta(id: '100', serverId: ServerId('plex1'), grandparentId: '42', parentId: '1'),
        'plex1:ep200': _episodeMeta(id: '200', serverId: ServerId('plex1'), grandparentId: '42', parentId: '2'),
      };

      expect(resolveDownloadContainerGlobalKey(show, metadata), 'plex1:42');
    });
  });

  group('determineDownloadAggregateStatus', () {
    test('all-cancelled children aggregate to cancelled, not completed', () {
      expect(determineDownloadAggregateStatus([DownloadStatus.cancelled]), DownloadStatus.cancelled);
      expect(
        determineDownloadAggregateStatus([DownloadStatus.cancelled, DownloadStatus.cancelled]),
        DownloadStatus.cancelled,
      );
    });

    test('completed mixed with cancelled aggregates to partial', () {
      expect(
        determineDownloadAggregateStatus([DownloadStatus.completed, DownloadStatus.cancelled]),
        DownloadStatus.partial,
      );
    });

    test('a partial child keeps the container partial', () {
      expect(determineDownloadAggregateStatus([DownloadStatus.partial]), DownloadStatus.partial);
      expect(
        determineDownloadAggregateStatus([DownloadStatus.completed, DownloadStatus.partial]),
        DownloadStatus.partial,
      );
    });

    test('active, paused, and failed precedence is unchanged', () {
      expect(
        determineDownloadAggregateStatus([
          DownloadStatus.completed,
          DownloadStatus.downloading,
          DownloadStatus.cancelled,
        ]),
        DownloadStatus.downloading,
      );
      expect(
        determineDownloadAggregateStatus([DownloadStatus.cancelled, DownloadStatus.queued]),
        DownloadStatus.queued,
      );
      expect(
        determineDownloadAggregateStatus([DownloadStatus.completed, DownloadStatus.paused]),
        DownloadStatus.paused,
      );
      expect(
        determineDownloadAggregateStatus([DownloadStatus.failed, DownloadStatus.completed]),
        DownloadStatus.failed,
      );
      expect(determineDownloadAggregateStatus([DownloadStatus.completed]), DownloadStatus.completed);
      expect(determineDownloadAggregateStatus(const []), DownloadStatus.queued);
    });
  });
}
