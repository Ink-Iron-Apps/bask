import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/widgets/download_tree_view.dart';

void main() {
  DownloadTreeNode leaf(String key, {required DownloadStatus status, int total = 0, int done = 0}) {
    return DownloadTreeNode(
      key: key,
      title: key,
      type: DownloadNodeType.episode,
      status: status,
      downloadProgress: DownloadProgress(
        globalKey: key,
        status: status,
        progress: 0,
        downloadedBytes: done,
        totalBytes: total,
      ),
    );
  }

  group('DownloadTreeNode.sizeBytes', () {
    test('a finished download reports its full size', () {
      expect(leaf('a', status: DownloadStatus.completed, total: 900, done: 900).sizeBytes, 900);
    });

    test('an unfinished download reports what has landed, not what it will be', () {
      // The question the row answers is "what is this costing me now".
      expect(leaf('a', status: DownloadStatus.downloading, total: 900, done: 250).sizeBytes, 250);
    });

    test('a row with no size information contributes nothing rather than a guess', () {
      const bare = DownloadTreeNode(
        key: 'a',
        title: 'a',
        type: DownloadNodeType.movie,
        status: DownloadStatus.completed,
      );
      expect(bare.sizeBytes, 0);
    });

    test('a group sums everything beneath it, at any depth', () {
      final season = DownloadTreeNode(
        key: 's1',
        title: 'Season 1',
        type: DownloadNodeType.season,
        status: DownloadStatus.completed,
        children: [
          leaf('e1', status: DownloadStatus.completed, total: 100, done: 100),
          leaf('e2', status: DownloadStatus.downloading, total: 100, done: 40),
        ],
      );
      final show = DownloadTreeNode(
        key: 'show',
        title: 'Show',
        type: DownloadNodeType.show,
        status: DownloadStatus.partial,
        children: [
          season,
          leaf('e3', status: DownloadStatus.completed, total: 60, done: 60),
        ],
      );

      expect(season.sizeBytes, 140);
      expect(show.sizeBytes, 200);
    });
  });
}
