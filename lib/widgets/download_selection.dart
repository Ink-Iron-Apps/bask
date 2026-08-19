import 'package:flutter/foundation.dart';

import '../models/download_models.dart';
import 'download_tree_view.dart';

/// The bulk actions a set of selected downloads can be given.
///
/// Which ones apply depends on what is selected: pausing a completed download
/// is meaningless, and retrying one that never failed would restart a finished
/// transfer. An action is offered when at least one selected download can take
/// it, and applied only to those that can.
enum DownloadBulkAction { pause, resume, retry, delete }

/// Selection state for the manage list.
///
/// Selecting a container means selecting the downloads underneath it: a show,
/// season or playlist is not itself a transfer, so the actions have to reach
/// its leaves. Keys are therefore always leaf keys, which keeps the applied
/// action unambiguous no matter what the user tapped.
@immutable
class DownloadSelection {
  final Set<String> selectedKeys;

  const DownloadSelection({this.selectedKeys = const {}});

  bool get isEmpty => selectedKeys.isEmpty;
  bool get isNotEmpty => selectedKeys.isNotEmpty;
  int get count => selectedKeys.length;

  bool contains(String globalKey) => selectedKeys.contains(globalKey);

  /// Every leaf key under [node], or the node itself when it is a leaf.
  static List<String> leafKeysOf(DownloadTreeNode node) {
    if (!node.hasChildren) return [node.key];
    return node.children.expand(leafKeysOf).toList();
  }

  /// Whether every leaf under [node] is selected. A container with nothing
  /// under it is not "fully selected" — there is nothing to select.
  bool containsAllOf(DownloadTreeNode node) {
    final keys = leafKeysOf(node);
    return keys.isNotEmpty && keys.every(selectedKeys.contains);
  }

  /// Whether some but not all of [node]'s leaves are selected.
  bool containsSomeOf(DownloadTreeNode node) {
    final keys = leafKeysOf(node);
    return keys.any(selectedKeys.contains) && !keys.every(selectedKeys.contains);
  }

  /// Adds [node]'s leaves, or removes them when they are already all selected,
  /// so tapping the same row twice returns to where it started.
  DownloadSelection toggle(DownloadTreeNode node) {
    final keys = leafKeysOf(node);
    final next = Set<String>.from(selectedKeys);
    if (containsAllOf(node)) {
      next.removeAll(keys);
    } else {
      next.addAll(keys);
    }
    return DownloadSelection(selectedKeys: next);
  }

  DownloadSelection selectAll(List<DownloadTreeNode> nodes) =>
      DownloadSelection(selectedKeys: nodes.expand(leafKeysOf).toSet());

  DownloadSelection clear() => const DownloadSelection();

  /// The actions worth showing for the current selection.
  ///
  /// Delete always applies — a download can be removed whatever state it is in.
  /// The rest are offered only when something selected could actually take
  /// them, so the bar never presents an action that would do nothing.
  Set<DownloadBulkAction> availableActions(Map<String, DownloadStatus> statusByKey) {
    if (isEmpty) return const {};

    final statuses = selectedKeys.map((key) => statusByKey[key]).nonNulls.toSet();
    return {
      if (statuses.any((s) => s == DownloadStatus.downloading || s == DownloadStatus.queued)) DownloadBulkAction.pause,
      if (statuses.contains(DownloadStatus.paused)) DownloadBulkAction.resume,
      if (statuses.contains(DownloadStatus.failed)) DownloadBulkAction.retry,
      DownloadBulkAction.delete,
    };
  }

  /// The selected downloads [action] should actually be applied to.
  List<String> keysFor(DownloadBulkAction action, Map<String, DownloadStatus> statusByKey) {
    bool takes(DownloadStatus? status) => switch (action) {
      DownloadBulkAction.pause => status == DownloadStatus.downloading || status == DownloadStatus.queued,
      DownloadBulkAction.resume => status == DownloadStatus.paused,
      DownloadBulkAction.retry => status == DownloadStatus.failed,
      DownloadBulkAction.delete => true,
    };
    return selectedKeys.where((key) => takes(statusByKey[key])).toList();
  }

  @override
  bool operator ==(Object other) => other is DownloadSelection && setEquals(other.selectedKeys, selectedKeys);

  @override
  int get hashCode => Object.hashAll(selectedKeys.toList()..sort());
}
