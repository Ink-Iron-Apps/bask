import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/widgets/download_selection.dart';
import 'package:plezy/widgets/download_tree_view.dart';

DownloadTreeNode _leaf(String key, [DownloadStatus status = DownloadStatus.completed]) =>
    DownloadTreeNode(key: key, title: key, type: DownloadNodeType.episode, status: status);

DownloadTreeNode _container(String key, List<DownloadTreeNode> children) => DownloadTreeNode(
  key: key,
  title: key,
  type: DownloadNodeType.season,
  status: DownloadStatus.completed,
  children: children,
);

void main() {
  group('selecting', () {
    test('a leaf selects just itself', () {
      final selection = const DownloadSelection().toggle(_leaf('e1'));

      expect(selection.selectedKeys, {'e1'});
      expect(selection.count, 1);
    });

    test('a container selects the downloads underneath it', () {
      // A season is not a transfer, so the action has to reach its episodes.
      final season = _container('s1', [_leaf('e1'), _leaf('e2')]);

      expect(const DownloadSelection().toggle(season).selectedKeys, {'e1', 'e2'});
    });

    test('nesting is followed to the leaves', () {
      final show = _container('show', [
        _container('s1', [_leaf('e1')]),
        _container('s2', [_leaf('e2'), _leaf('e3')]),
      ]);

      expect(const DownloadSelection().toggle(show).selectedKeys, {'e1', 'e2', 'e3'});
    });

    test('tapping the same row twice returns to where it started', () {
      final season = _container('s1', [_leaf('e1'), _leaf('e2')]);
      final selection = const DownloadSelection().toggle(season);

      expect(selection.toggle(season).isEmpty, isTrue);
    });

    test('deselecting one episode leaves the rest of its season selected', () {
      final season = _container('s1', [_leaf('e1'), _leaf('e2')]);
      final selection = const DownloadSelection().toggle(season).toggle(_leaf('e1'));

      expect(selection.selectedKeys, {'e2'});
    });

    test('a partly selected container reports as partial, not full', () {
      final season = _container('s1', [_leaf('e1'), _leaf('e2')]);
      final selection = const DownloadSelection().toggle(_leaf('e1'));

      expect(selection.containsSomeOf(season), isTrue);
      expect(selection.containsAllOf(season), isFalse);
    });

    test('a container with nothing under it is not fully selected', () {
      expect(const DownloadSelection().containsAllOf(_container('empty', const [])), isFalse);
    });

    test('select all takes every leaf, clear takes none', () {
      final nodes = [
        _container('s1', [_leaf('e1'), _leaf('e2')]),
        _leaf('m1'),
      ];
      final all = const DownloadSelection().selectAll(nodes);

      expect(all.selectedKeys, {'e1', 'e2', 'm1'});
      expect(all.clear().isEmpty, isTrue);
    });
  });

  group('available actions', () {
    const statuses = {
      'downloading': DownloadStatus.downloading,
      'queued': DownloadStatus.queued,
      'paused': DownloadStatus.paused,
      'failed': DownloadStatus.failed,
      'done': DownloadStatus.completed,
    };

    DownloadSelection select(Set<String> keys) => DownloadSelection(selectedKeys: keys);

    test('nothing selected offers nothing', () {
      expect(const DownloadSelection().availableActions(statuses), isEmpty);
    });

    test('an active download can be paused', () {
      expect(select({'downloading'}).availableActions(statuses), contains(DownloadBulkAction.pause));
      expect(select({'queued'}).availableActions(statuses), contains(DownloadBulkAction.pause));
    });

    test('a finished download offers only delete', () {
      expect(select({'done'}).availableActions(statuses), {DownloadBulkAction.delete});
    });

    test('a mixed selection offers every action something can take', () {
      expect(select({'downloading', 'paused', 'failed', 'done'}).availableActions(statuses), {
        DownloadBulkAction.pause,
        DownloadBulkAction.resume,
        DownloadBulkAction.retry,
        DownloadBulkAction.delete,
      });
    });

    test('an action applies only to the downloads that can take it', () {
      final selection = select({'downloading', 'paused', 'failed', 'done'});

      expect(selection.keysFor(DownloadBulkAction.pause, statuses), ['downloading']);
      expect(selection.keysFor(DownloadBulkAction.resume, statuses), ['paused']);
      expect(selection.keysFor(DownloadBulkAction.retry, statuses), ['failed']);
      expect(selection.keysFor(DownloadBulkAction.delete, statuses).toSet(), selection.selectedKeys);
    });

    test('a download with no known status is skipped rather than acted on blindly', () {
      final selection = select({'downloading', 'ghost'});

      expect(selection.availableActions(statuses), {DownloadBulkAction.pause, DownloadBulkAction.delete});
      expect(selection.keysFor(DownloadBulkAction.pause, statuses), ['downloading']);
    });
  });
}
