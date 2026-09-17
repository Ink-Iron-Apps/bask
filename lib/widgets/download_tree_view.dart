import '../utils/formatters.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../media/ids.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../focus/focusable_wrapper.dart';
import '../i18n/strings.g.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../models/download_models.dart';
import 'download_selection.dart';
import '../utils/dialogs.dart';
import '../utils/global_key_utils.dart';
import '../mixins/unsuppress_focus_mixin.dart';
import 'download_status_icon.dart';

/// Represents a node in the download tree
class DownloadTreeNode {
  final String key;
  final String title;
  final DownloadNodeType type;
  final double progress; // 0.0-1.0
  final DownloadStatus status;
  final List<DownloadTreeNode> children;
  final MediaItem? metadata;
  final DownloadProgress? downloadProgress;

  const DownloadTreeNode({
    required this.key,
    required this.title,
    required this.type,
    this.progress = 0.0,
    required this.status,
    this.children = const [],
    this.metadata,
    this.downloadProgress,
  });

  /// Check if this node has children
  bool get hasChildren => children.isNotEmpty;

  /// Get the number of completed children
  int get completedChildrenCount {
    return children.where((child) => child.status == DownloadStatus.completed).length;
  }

  /// Every download below this node, at any depth.
  ///
  /// A show's children are seasons, so counting children reported a show as
  /// "0/4" — its season count — when what is being downloaded is episodes.
  int get leafCount {
    if (!hasChildren) return 1;
    return children.fold(0, (sum, child) => sum + child.leafCount);
  }

  int get completedLeafCount {
    if (!hasChildren) return status == DownloadStatus.completed ? 1 : 0;
    return children.fold(0, (sum, child) => sum + child.completedLeafCount);
  }

  /// Bytes this node occupies on the device, summed over everything below it.
  ///
  /// A finished download is its total size; one still running is what has
  /// landed so far, which is what the device is actually holding. A row with
  /// no size information contributes nothing rather than guessing — the sum
  /// is meant to answer "what is this costing me", and an invented number
  /// would answer it wrongly.
  int get sizeBytes {
    if (!hasChildren) {
      final progress = downloadProgress;
      if (progress == null) return 0;
      return status == DownloadStatus.completed && progress.totalBytes > 0
          ? progress.totalBytes
          : progress.downloadedBytes;
    }
    return children.fold(0, (sum, child) => sum + child.sizeBytes);
  }
}

/// Type of node in the download tree
enum DownloadNodeType { playlist, show, season, episode, movie, album, track }

/// A playlist whose downloaded contents should group under it.
///
/// A playlist's items are ordinary movies, episodes and tracks, so nothing on
/// the download itself says which list pulled it in. The membership comes from
/// the sync rule that queued them.
class DownloadPlaylistGroup {
  /// The rule's global key, used as the tree node key.
  final String key;
  final String title;
  final Set<String> memberKeys;

  const DownloadPlaylistGroup({required this.key, required this.title, required this.memberKeys});
}

extension DownloadTreeNodeActivity on DownloadTreeNode {
  /// Whether this node still has work outstanding, and so belongs at the top of
  /// the manage list. Failed and cancelled rows are finished, not outstanding.
  bool get isActive =>
      status == DownloadStatus.downloading || status == DownloadStatus.queued || status == DownloadStatus.paused;
}

/// Hierarchical tree view for downloads
/// Groups TV shows by show -> season -> episode and music by album -> track
/// Movies appear at top level
class DownloadTreeView extends StatefulWidget {
  final Map<String, DownloadProgress> downloads;
  final Map<String, MediaItem> metadata;

  /// Playlists whose downloaded contents should group under their title.
  final List<DownloadPlaylistGroup> playlists;
  final void Function(String globalKey)? onPause;
  final void Function(String globalKey)? onResume;
  final void Function(String globalKey)? onRetry;
  final void Function(String globalKey)? onCancel;
  final void Function(String globalKey)? onDelete;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;
  final bool suppressAutoFocus;

  const DownloadTreeView({
    super.key,
    required this.downloads,
    required this.metadata,
    this.playlists = const [],
    this.onPause,
    this.onResume,
    this.onRetry,
    this.onCancel,
    this.onDelete,
    this.onNavigateLeft,
    this.onBack,
    this.suppressAutoFocus = false,
  });

  @override
  State<DownloadTreeView> createState() => _DownloadTreeViewState();
}

class _DownloadTreeViewState extends State<DownloadTreeView> with UnsuppressFocusFirstMixin<DownloadTreeView> {
  final Set<String> _expandedNodes = {};
  DownloadSelection _selection = const DownloadSelection();
  bool _selecting = false;

  @override
  String get firstItemFocusDebugLabel => 'DownloadTreeView_firstItem';

  @override
  bool suppressAutoFocusOf(DownloadTreeView widget) => widget.suppressAutoFocus;

  @override
  Widget build(BuildContext context) {
    final tree = buildDownloadTree(downloads: widget.downloads, metadata: widget.metadata, playlists: widget.playlists);
    final flattenedNodes = _flattenTree(tree);

    if (flattenedNodes.isEmpty) {
      return Center(child: Text(t.downloads.noDownloadsTree));
    }

    final list = ListView.builder(
      padding: .zero,
      itemCount: flattenedNodes.length,
      itemBuilder: (context, index) {
        final item = flattenedNodes[index];
        return _buildTreeItem(item.node, item.depth, isFirst: index == 0);
      },
    );

    if (!_selecting) return list;

    // Back leaves selection rather than the screen: the list is inside a tab,
    // so popping would take the whole tab with it.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelecting();
      },
      child: Column(
        children: [
          _buildSelectionBar(tree),
          Expanded(child: list),
        ],
      ),
    );
  }

  Widget _buildSelectionBar(List<DownloadTreeNode> tree) {
    final theme = Theme.of(context);
    final statuses = _leafStatuses(tree);
    final available = _selection.availableActions(statuses);

    ({IconData icon, String tooltip}) describe(DownloadBulkAction action) => switch (action) {
      DownloadBulkAction.pause => (icon: Symbols.pause_rounded, tooltip: t.downloads.pauseSelected),
      DownloadBulkAction.resume => (icon: Symbols.play_arrow_rounded, tooltip: t.downloads.resumeSelected),
      DownloadBulkAction.retry => (icon: Symbols.refresh_rounded, tooltip: t.downloads.retrySelected),
      DownloadBulkAction.delete => (icon: Symbols.delete_rounded, tooltip: t.downloads.deleteSelected),
    };

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const AppIcon(Symbols.close_rounded, fill: 1),
                tooltip: t.common.cancel,
                onPressed: _exitSelecting,
              ),
              Expanded(
                child: Text(
                  t.downloads.selectedCount(count: _selection.count),
                  style: theme.textTheme.titleMedium,
                  overflow: .ellipsis,
                ),
              ),
              IconButton(
                icon: const AppIcon(Symbols.select_all_rounded, fill: 1),
                tooltip: t.downloads.selectAll,
                onPressed: () => setState(() => _selection = _selection.selectAll(tree)),
              ),
              for (final action in DownloadBulkAction.values)
                if (available.contains(action))
                  IconButton(
                    icon: AppIcon(describe(action).icon, fill: 1),
                    tooltip: describe(action).tooltip,
                    color: action == DownloadBulkAction.delete ? theme.colorScheme.error : null,
                    onPressed: () => unawaited(_applyBulkAction(action, statuses)),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  // tree building lives at the bottom of this file as a pure function
  /// Flatten the tree into a list of visible nodes with their depths
  List<_FlatNode> _flattenTree(List<DownloadTreeNode> nodes, [int depth = 0]) {
    final List<_FlatNode> result = [];

    for (final node in nodes) {
      result.add(_FlatNode(node: node, depth: depth));

      // Add children if node is expanded
      if (_expandedNodes.contains(node.key) && node.hasChildren) {
        result.addAll(_flattenTree(node.children, depth + 1));
      }
    }

    return result;
  }

  /// Toggle node expansion
  void _toggleExpansion(String key) {
    setState(() {
      if (_expandedNodes.contains(key)) {
        _expandedNodes.remove(key);
      } else {
        _expandedNodes.add(key);
      }
    });
  }

  Widget _buildTreeItem(DownloadTreeNode node, int depth, {bool isFirst = false}) {
    return _DownloadTreeItem(
      node: node,
      depth: depth,
      isExpanded: _expandedNodes.contains(node.key),
      onToggleExpansion: () => _toggleExpansion(node.key),
      onPause: widget.onPause,
      onResume: widget.onResume,
      onRetry: widget.onRetry,
      onCancel: widget.onCancel,
      onDelete: widget.onDelete,
      onNavigateLeft: widget.onNavigateLeft,
      onBack: widget.onBack,
      rowFocusNode: isFirst ? firstItemFocusNode : null,
      autofocus: isFirst && !widget.suppressAutoFocus,
      selecting: _selecting,
      isSelected: _selection.containsAllOf(node),
      isPartiallySelected: _selection.containsSomeOf(node),
      onToggleSelected: () => _toggleSelected(node),
      onStartSelecting: () => _startSelecting(node),
      pauseAllChildren: _pauseAllChildren,
      resumeAllChildren: _resumeAllChildren,
      retryAllChildren: _retryAllChildren,
      deleteAllChildren: _deleteAllChildren,
    );
  }

  /// Pause all active (downloading and queued) children of a container node
  void _pauseAllChildren(DownloadTreeNode node) {
    final keys = _leafKeys(
      node,
      where: (leaf) => leaf.status == DownloadStatus.downloading || leaf.status == DownloadStatus.queued,
    );
    for (final key in keys) {
      widget.onPause?.call(key);
    }
  }

  /// Resume all paused children of a container node
  void _resumeAllChildren(DownloadTreeNode node) {
    final keys = _leafKeys(node, where: (leaf) => leaf.status == DownloadStatus.paused);
    for (final key in keys) {
      widget.onResume?.call(key);
    }
  }

  void _startSelecting(DownloadTreeNode node) {
    setState(() {
      _selecting = true;
      _selection = _selection.toggle(node);
    });
  }

  void _toggleSelected(DownloadTreeNode node) {
    setState(() {
      _selection = _selection.toggle(node);
      // Clearing the last item leaves selection mode, so the list never sits in
      // a mode with nothing to act on.
      if (_selection.isEmpty) _selecting = false;
    });
  }

  void _exitSelecting() {
    setState(() {
      _selecting = false;
      _selection = const DownloadSelection();
    });
  }

  /// Status of every download in the tree, keyed the way the selection is.
  Map<String, DownloadStatus> _leafStatuses(List<DownloadTreeNode> nodes) {
    final statuses = <String, DownloadStatus>{};
    void walk(DownloadTreeNode node) {
      if (!node.hasChildren) {
        statuses[node.key] = node.status;
        return;
      }
      node.children.forEach(walk);
    }

    nodes.forEach(walk);
    return statuses;
  }

  Future<void> _applyBulkAction(DownloadBulkAction action, Map<String, DownloadStatus> statuses) async {
    final keys = _selection.keysFor(action, statuses);
    if (keys.isEmpty) return;
    if (action == DownloadBulkAction.delete && !await _confirmBulkDelete(keys.length)) return;

    for (final key in keys) {
      switch (action) {
        case DownloadBulkAction.pause:
          widget.onPause?.call(key);
        case DownloadBulkAction.resume:
          widget.onResume?.call(key);
        case DownloadBulkAction.retry:
          widget.onRetry?.call(key);
        case DownloadBulkAction.delete:
          widget.onDelete?.call(key);
      }
    }
    if (mounted) _exitSelecting();
  }

  Future<bool> _confirmBulkDelete(int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.downloads.deleteDownload),
        content: Text(t.downloads.deleteSelectedConfirm(count: count)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.common.delete)),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Retry every failed child of a container node
  void _retryAllChildren(DownloadTreeNode node) {
    final keys = _leafKeys(node, where: (leaf) => leaf.status == DownloadStatus.failed);
    for (final key in keys) {
      widget.onRetry?.call(key);
    }
  }

  /// Delete all children of a container node via the container's globalKey
  /// so deleteDownload's transitive show/season path cleans up all maps.
  void _deleteAllChildren(DownloadTreeNode node) {
    final containerKey = resolveDownloadContainerGlobalKey(node, widget.metadata);
    if (containerKey != null) {
      widget.onDelete?.call(containerKey);
      return;
    }

    // Container globalKey unresolvable; fall back to per-leaf delete.
    for (final key in _leafKeys(node)) {
      widget.onDelete?.call(key);
    }
  }

  /// Get the keys of every leaf below a container node, in tree order.
  /// [where] filters which leaves are collected; unset collects all of them.
  List<String> _leafKeys(DownloadTreeNode node, {bool Function(DownloadTreeNode leaf)? where}) {
    final List<String> keys = [];
    for (final child in node.children) {
      if (child.hasChildren) {
        keys.addAll(_leafKeys(child, where: where));
      } else if (where == null || where(child)) {
        keys.add(child.key);
      }
    }
    return keys;
  }
}

/// Tree-node keys for shows/seasons aren't provider globalKeys; reconstruct
/// from any leaf episode's serverId + grandparentId/parentId.
@visibleForTesting
String? resolveDownloadContainerGlobalKey(DownloadTreeNode node, Map<String, MediaItem> metadata) {
  final firstLeafKey = _firstLeafKey(node);
  if (firstLeafKey == null) return null;
  final firstLeafMeta = metadata[firstLeafKey];
  final serverId = firstLeafMeta?.serverId;
  if (serverId == null) return null;
  switch (node.type) {
    // A playlist is not a server-side parent of its items — its key is the sync
    // rule's own global key, which is already the container key.
    case DownloadNodeType.playlist:
      return node.key;
    case DownloadNodeType.show:
      final showRatingKey = firstLeafMeta!.grandparentId;
      if (showRatingKey == null) return null;
      return buildGlobalKey(ServerId(serverId), showRatingKey);
    case DownloadNodeType.season:
    case DownloadNodeType.album:
      final parentRatingKey = firstLeafMeta!.parentId;
      if (parentRatingKey == null) return null;
      return buildGlobalKey(ServerId(serverId), parentRatingKey);
    case DownloadNodeType.episode:
    case DownloadNodeType.movie:
    case DownloadNodeType.track:
      return null;
  }
}

String? _firstLeafKey(DownloadTreeNode node) {
  for (final child in node.children) {
    if (child.hasChildren) {
      final result = _firstLeafKey(child);
      if (result != null) return result;
    } else {
      return child.key;
    }
  }
  return null;
}

/// Helper class to store a node with its depth in the flattened tree
class _FlatNode {
  final DownloadTreeNode node;
  final int depth;

  const _FlatNode({required this.node, required this.depth});
}

/// A single action button of a tree row: the guards that decide which actions
/// exist live in one place ([_DownloadTreeItemState._actions]), so the focus
/// node count and the rendered buttons can never disagree.
typedef _RowAction = ({IconData icon, String tooltip, VoidCallback onPressed});

/// A single tree item with focusable row content and action buttons
class _DownloadTreeItem extends StatefulWidget {
  final DownloadTreeNode node;
  final int depth;
  final bool isExpanded;
  final VoidCallback onToggleExpansion;
  final void Function(String globalKey)? onPause;
  final void Function(String globalKey)? onResume;
  final void Function(String globalKey)? onRetry;
  final void Function(String globalKey)? onCancel;
  final void Function(String globalKey)? onDelete;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;
  final FocusNode? rowFocusNode;
  final bool autofocus;
  final void Function(DownloadTreeNode) pauseAllChildren;
  final void Function(DownloadTreeNode) resumeAllChildren;
  final void Function(DownloadTreeNode) retryAllChildren;
  final void Function(DownloadTreeNode) deleteAllChildren;
  final bool selecting;
  final bool isSelected;
  final bool isPartiallySelected;
  final VoidCallback onToggleSelected;
  final VoidCallback onStartSelecting;

  const _DownloadTreeItem({
    required this.node,
    required this.depth,
    required this.isExpanded,
    required this.onToggleExpansion,
    this.onPause,
    this.onResume,
    this.onRetry,
    this.onCancel,
    this.onDelete,
    this.onNavigateLeft,
    this.onBack,
    this.rowFocusNode,
    this.autofocus = false,
    required this.pauseAllChildren,
    required this.resumeAllChildren,
    required this.retryAllChildren,
    required this.deleteAllChildren,
    required this.selecting,
    required this.isSelected,
    required this.isPartiallySelected,
    required this.onToggleSelected,
    required this.onStartSelecting,
  });

  @override
  State<_DownloadTreeItem> createState() => _DownloadTreeItemState();
}

class _DownloadTreeItemState extends State<_DownloadTreeItem> {
  /// Treat downloading items with no progress/speed as effectively queued
  /// (they're waiting in background_downloader's HoldingQueue).
  DownloadStatus get _effectiveStatus {
    if (widget.node.status == DownloadStatus.downloading &&
        widget.node.progress == 0 &&
        (widget.node.downloadProgress?.speed ?? 0) == 0) {
      return DownloadStatus.queued;
    }
    return widget.node.status;
  }

  FocusNode? _ownedRowFocusNode;
  final List<FocusNode> _buttonFocusNodes = [];

  FocusNode get _rowFocusNode => widget.rowFocusNode ?? _ownedRowFocusNode!;

  @override
  void initState() {
    super.initState();
    _initRowFocusNode();
    _initButtonFocusNodes();
  }

  @override
  void didUpdateWidget(_DownloadTreeItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reinitialize focus nodes if action count changed
    if (_actions().length != _buttonFocusNodes.length) {
      _disposeButtonFocusNodes();
      _initButtonFocusNodes();
    }
  }

  void _initRowFocusNode() {
    if (widget.rowFocusNode == null) {
      _ownedRowFocusNode = FocusNode(debugLabel: 'download_row_${widget.node.key}');
    }
  }

  void _initButtonFocusNodes() {
    final actionCount = _actions().length;
    for (int i = 0; i < actionCount; i++) {
      _buttonFocusNodes.add(FocusNode(debugLabel: 'download_action_$i'));
    }
  }

  void _disposeButtonFocusNodes() {
    for (final node in _buttonFocusNodes) {
      node.dispose();
    }
    _buttonFocusNodes.clear();
  }

  @override
  void dispose() {
    _ownedRowFocusNode?.dispose();
    _disposeButtonFocusNodes();
    super.dispose();
  }

  void _focusFirstButton() {
    if (_buttonFocusNodes.isNotEmpty) {
      _buttonFocusNodes.first.requestFocus();
    }
  }

  void _focusRow() {
    _rowFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canExpand = widget.node.hasChildren;
    final actions = _actions();

    return Padding(
      padding: .only(left: widget.depth * 16.0),
      child: FocusableWrapper(
        focusNode: _rowFocusNode,
        autofocus: widget.autofocus,
        onSelect: canExpand ? widget.onToggleExpansion : null,
        onNavigateLeft: widget.onNavigateLeft,
        onNavigateRight: actions.isNotEmpty ? _focusFirstButton : null,
        onBack: widget.onBack,
        borderRadius: 8.0,
        disableScale: true,
        useBackgroundFocus: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.selecting ? widget.onToggleSelected : (canExpand ? widget.onToggleExpansion : null),
          onLongPress: widget.selecting ? null : widget.onStartSelecting,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                if (widget.selecting)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Checkbox(
                      value: widget.isSelected ? true : (widget.isPartiallySelected ? null : false),
                      tristate: true,
                      onChanged: (_) => widget.onToggleSelected(),
                    ),
                  ),
                Expanded(child: _buildRowContent(theme, canExpand)),

                // Per-row actions would compete with the bulk bar for the same
                // gestures, so they step aside while selecting.
                if (actions.isNotEmpty && !widget.selecting)
                  Row(
                    mainAxisSize: .min,
                    children: [for (int i = 0; i < actions.length; i++) _buildActionButton(actions[i], i)],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRowContent(ThemeData theme, bool canExpand) {
    return Row(
      children: [
        if (canExpand)
          AppIcon(widget.isExpanded ? Symbols.expand_more_rounded : Symbols.chevron_right_rounded, fill: 1, size: 20)
        else
          const SizedBox(width: 20),

        const SizedBox(width: 8),

        DownloadStatusIcon(status: _effectiveStatus, size: 20),

        const SizedBox(width: 12),

        Expanded(
          child: Column(
            crossAxisAlignment: .start,
            mainAxisSize: .min,
            children: [
              Text(
                widget.node.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: canExpand ? FontWeight.w600 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: .ellipsis,
              ),

              if (canExpand) ...[
                const SizedBox(height: 4),
                Text(
                  _getNodeSummary(),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
              ]
              // A single download says its own size. Not while it is running:
              // the progress line below already reports what has landed, and
              // two numbers for one transfer read as a discrepancy.
              else if (widget.node.sizeBytes > 0 && _effectiveStatus != DownloadStatus.downloading) ...[
                const SizedBox(height: 4),
                Text(
                  ByteFormatter.formatBytes(widget.node.sizeBytes),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
              ],

              // Progress bar for active downloads
              if (_effectiveStatus == DownloadStatus.downloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: widget.node.progress,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                if (widget.node.downloadProgress != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${(widget.node.progress * 100).toStringAsFixed(1)}% - ${widget.node.downloadProgress!.speedFormatted}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ],

              // Queued label
              if (_effectiveStatus == DownloadStatus.queued) ...[
                const SizedBox(height: 4),
                Text(
                  t.downloads.downloadQueued,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                ),
              ],

              // Error message for failed downloads
              if (_effectiveStatus == DownloadStatus.failed && widget.node.downloadProgress?.errorMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.node.downloadProgress!.errorMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.red.withValues(alpha: 0.8)),
                  maxLines: 2,
                  overflow: .ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _getNodeSummary() {
    final total = widget.node.leafCount;
    final completed = widget.node.completedLeafCount;
    final counts = t.downloads.completedOfTotal(completed: completed, total: total);
    final size = widget.node.sizeBytes;
    // Nothing measured yet reads as a plain count rather than "0 B", which
    // would claim the group is free.
    return size > 0 ? '$counts · ${ByteFormatter.formatBytes(size)}' : counts;
  }

  /// The actions this row offers, in render order. Single source of truth:
  /// both the button widgets and the focus nodes sizing come from this list,
  /// so they cannot drift apart. Uses the raw node status, not
  /// [_effectiveStatus] (which only remaps the row content).
  List<_RowAction> _actions() {
    final status = widget.node.status;
    final isContainer =
        widget.node.type == DownloadNodeType.playlist ||
        widget.node.type == DownloadNodeType.show ||
        widget.node.type == DownloadNodeType.season ||
        widget.node.type == DownloadNodeType.album;
    final actions = <_RowAction>[];

    if (isContainer) {
      // Pause all button
      if ((status == DownloadStatus.downloading || status == DownloadStatus.queued) && widget.onPause != null) {
        actions.add((
          icon: Symbols.pause_rounded,
          tooltip: t.downloads.pauseAll,
          onPressed: () => widget.pauseAllChildren(widget.node),
        ));
      }

      // Resume all button
      if (status == DownloadStatus.paused && widget.onResume != null) {
        actions.add((
          icon: Symbols.play_arrow_rounded,
          tooltip: t.downloads.resumeAll,
          onPressed: () => widget.resumeAllChildren(widget.node),
        ));
      }

      // Retry all button. Driven by whether any leaf actually failed rather
      // than by the container's aggregate status, which reports the most
      // pressing state — a container still downloading hides its failures.
      if (widget.onRetry != null && hasFailedLeaf(widget.node)) {
        actions.add((
          icon: Symbols.refresh_rounded,
          tooltip: t.downloads.retryAll,
          onPressed: () => widget.retryAllChildren(widget.node),
        ));
      }

      // Delete all button
      if (widget.onDelete != null) {
        actions.add((
          icon: Symbols.delete_sweep_rounded,
          tooltip: t.downloads.deleteAll,
          onPressed: () async {
            if (await _confirmDelete()) widget.deleteAllChildren(widget.node);
          },
        ));
      }

      return actions;
    }

    final globalKey = widget.node.key;

    // Pause button for downloading items
    if (status == DownloadStatus.downloading && widget.onPause != null) {
      actions.add((icon: Symbols.pause_rounded, tooltip: t.common.pause, onPressed: () => widget.onPause!(globalKey)));
    }

    // Resume button for paused items
    if (status == DownloadStatus.paused && widget.onResume != null) {
      actions.add((
        icon: Symbols.play_arrow_rounded,
        tooltip: t.common.resume,
        onPressed: () => widget.onResume!(globalKey),
      ));
    }

    // Cancel button for downloading/queued items
    if ((status == DownloadStatus.downloading || status == DownloadStatus.queued) && widget.onCancel != null) {
      actions.add((
        icon: Symbols.close_rounded,
        tooltip: t.common.cancel,
        onPressed: () => widget.onCancel!(globalKey),
      ));
    }

    // Retry button for failed items
    if (status == DownloadStatus.failed && widget.onRetry != null) {
      actions.add((
        icon: Symbols.refresh_rounded,
        tooltip: t.downloads.retryDownload,
        onPressed: () => widget.onRetry!(globalKey),
      ));
    }

    // Delete button for completed/failed/cancelled items
    if ((status == DownloadStatus.completed || status == DownloadStatus.failed || status == DownloadStatus.cancelled) &&
        widget.onDelete != null) {
      actions.add((
        icon: Symbols.delete_rounded,
        tooltip: t.common.delete,
        onPressed: () async {
          if (await _confirmDelete()) widget.onDelete!(globalKey);
        },
      ));
    }

    return actions;
  }

  Future<bool> _confirmDelete() {
    return showDeleteConfirmation(
      context,
      title: t.downloads.deleteDownload,
      message: t.downloads.deleteConfirm(title: widget.node.title),
    );
  }

  /// Edge of the square a row action answers taps within.
  static const double _actionButtonTarget = 48.0;

  Widget _buildActionButton(_RowAction action, int buttonIndex) {
    final isFirst = buttonIndex == 0;
    final isLast = buttonIndex == _buttonFocusNodes.length - 1;

    return FocusableWrapper(
      focusNode: _buttonFocusNodes[buttonIndex],
      onSelect: action.onPressed,
      onNavigateLeft: isFirst ? _focusRow : () => _buttonFocusNodes[buttonIndex - 1].requestFocus(),
      onNavigateRight: isLast ? null : () => _buttonFocusNodes[buttonIndex + 1].requestFocus(),
      onBack: widget.onBack,
      borderRadius: 20.0,
      disableScale: true,
      useBackgroundFocus: true,
      autoScroll: false,
      child: Tooltip(
        message: action.tooltip,
        child: GestureDetector(
          // Without an opaque behaviour the gesture defers to the child, so only
          // the glyph itself answered a tap and the padding around it did
          // nothing — a 20dp target on a row of three adjacent buttons.
          behavior: HitTestBehavior.opaque,
          onTap: action.onPressed,
          child: SizedBox(
            // Material's minimum comfortable target. These sit in a row at the
            // end of a dense list, where a miss hits the neighbouring action.
            width: _actionButtonTarget,
            height: _actionButtonTarget,
            child: Center(child: AppIcon(action.icon, fill: 1, size: 22)),
          ),
        ),
      ),
    );
  }
}

/// Whether any leaf below [node] failed, at any depth.
///
/// Drives the retry-all button: the container's own aggregate status reports
/// the most pressing state, so a container still downloading would hide the
/// failures underneath it.
bool hasFailedLeaf(DownloadTreeNode node) {
  if (!node.hasChildren) return node.status == DownloadStatus.failed;
  return node.children.any(hasFailedLeaf);
}

/// Builds the manage-tab tree: shows -> seasons -> episodes, albums -> tracks,
/// movies at the top level.
///
/// Pulled out of the widget so the ordering rules can be tested directly.
List<DownloadTreeNode> buildDownloadTree({
  required Map<String, DownloadProgress> downloads,
  required Map<String, MediaItem> metadata,
  List<DownloadPlaylistGroup> playlists = const [],
}) {
  final Map<String, List<MapEntry<String, DownloadProgress>>> showGroups = {};
  final Map<String, List<MapEntry<String, DownloadProgress>>> albumGroups = {};
  final List<DownloadTreeNode> movies = [];

  // Which playlist owns each download. A download in two playlists lands in the
  // first, so it appears once rather than being duplicated down the list.
  final playlistByDownloadKey = <String, DownloadPlaylistGroup>{};
  for (final playlist in playlists) {
    for (final memberKey in playlist.memberKeys) {
      playlistByDownloadKey.putIfAbsent(memberKey, () => playlist);
    }
  }
  final playlistMembers = <String, List<MapEntry<String, DownloadProgress>>>{};

  for (final entry in downloads.entries) {
    final globalKey = entry.key;
    final download = entry.value;
    final meta = metadata[globalKey];

    if (meta == null) continue;

    final owningPlaylist = playlistByDownloadKey[globalKey];
    if (owningPlaylist != null) {
      playlistMembers.putIfAbsent(owningPlaylist.key, () => []).add(entry);
      continue;
    }

    if (meta.isEpisode) {
      final showKey = meta.grandparentId ?? 'unknown';
      showGroups.putIfAbsent(showKey, () => []);
      showGroups[showKey]!.add(entry);
    } else if (meta.kind == MediaKind.track) {
      final albumKey = meta.parentId ?? 'unknown';
      albumGroups.putIfAbsent(albumKey, () => []);
      albumGroups[albumKey]!.add(entry);
    } else if (meta.isMovie) {
      movies.add(
        DownloadTreeNode(
          key: globalKey,
          title: meta.displayTitle,
          type: DownloadNodeType.movie,
          progress: download.progressPercent,
          status: download.status,
          metadata: meta,
          downloadProgress: download,
        ),
      );
    }
  }

  final List<DownloadTreeNode> shows = [];
  for (final showEntry in showGroups.entries) {
    final showKey = showEntry.key;
    final episodes = showEntry.value;

    if (episodes.isEmpty) continue;

    final firstEpisode = metadata[episodes.first.key];
    final showTitle = firstEpisode?.grandparentTitle ?? t.downloads.unknownShow;

    final Map<String, List<MapEntry<String, DownloadProgress>>> seasonGroups = {};
    for (final episode in episodes) {
      final meta = metadata[episode.key];
      if (meta == null) continue;

      final seasonKey = meta.parentId ?? 'unknown';
      seasonGroups.putIfAbsent(seasonKey, () => []);
      seasonGroups[seasonKey]!.add(episode);
    }

    final List<DownloadTreeNode> seasons = [];
    for (final seasonEntry in seasonGroups.entries) {
      final seasonKey = seasonEntry.key;
      final seasonEpisodes = seasonEntry.value;

      if (seasonEpisodes.isEmpty) continue;

      final firstEpisode = metadata[seasonEpisodes.first.key];
      final seasonNumber = firstEpisode?.parentIndex;
      final seasonTitle = firstEpisode?.parentTitle?.isNotEmpty == true
          ? firstEpisode!.parentTitle!
          : seasonNumber != null
          ? t.common.seasonNumber(number: seasonNumber)
          : t.downloads.unknownSeason;

      final List<DownloadTreeNode> episodeNodes = [];
      for (final episodeEntry in seasonEpisodes) {
        final globalKey = episodeEntry.key;
        final download = episodeEntry.value;
        final meta = metadata[globalKey];

        if (meta == null) continue;

        final episodeNumber = meta.index;
        final episodeTitle = episodeNumber != null
            ? t.common.episodeNumberTitle(number: episodeNumber, title: meta.title!)
            : meta.title!;

        episodeNodes.add(
          DownloadTreeNode(
            key: globalKey,
            title: episodeTitle,
            type: DownloadNodeType.episode,
            progress: download.progressPercent,
            status: download.status,
            metadata: meta,
            downloadProgress: download,
          ),
        );
      }

      episodeNodes.sort((a, b) {
        final aIndex = a.metadata?.index ?? 0;
        final bIndex = b.metadata?.index ?? 0;
        return aIndex.compareTo(bIndex);
      });

      final seasonProgress = episodeNodes.isEmpty
          ? 0.0
          : episodeNodes.map((e) => e.progress).reduce((a, b) => a + b) / episodeNodes.length;
      final seasonStatus = determineDownloadAggregateStatus(episodeNodes.map((e) => e.status).toList());

      seasons.add(
        DownloadTreeNode(
          key: '$showKey:$seasonKey',
          title: seasonTitle,
          type: DownloadNodeType.season,
          progress: seasonProgress,
          status: seasonStatus,
          children: episodeNodes,
        ),
      );
    }

    seasons.removeWhere((s) => s.children.isEmpty);

    seasons.sort((a, b) {
      final aSeasonNum = metadata[a.children.first.key]?.parentIndex ?? 0;
      final bSeasonNum = metadata[b.children.first.key]?.parentIndex ?? 0;
      return aSeasonNum.compareTo(bSeasonNum);
    });

    final showProgress = seasons.isEmpty
        ? 0.0
        : seasons.map((s) => s.progress).reduce((a, b) => a + b) / seasons.length;
    final showStatus = determineDownloadAggregateStatus(seasons.map((s) => s.status).toList());

    shows.add(
      DownloadTreeNode(
        key: showKey,
        title: showTitle,
        type: DownloadNodeType.show,
        progress: showProgress,
        status: showStatus,
        children: seasons,
      ),
    );
  }

  final List<DownloadTreeNode> albums = [];
  for (final albumEntry in albumGroups.entries) {
    final albumKey = albumEntry.key;
    final tracks = albumEntry.value;
    if (tracks.isEmpty) continue;

    final firstTrack = metadata[tracks.first.key];
    final albumTitle = firstTrack?.albumTitle ?? t.downloads.unknownAlbum;
    final artistTitle = firstTrack?.albumArtistTitle;
    final albumNodeTitle = artistTitle != null && artistTitle.isNotEmpty ? '$artistTitle - $albumTitle' : albumTitle;

    final List<DownloadTreeNode> trackNodes = [];
    for (final trackEntry in tracks) {
      final globalKey = trackEntry.key;
      final download = trackEntry.value;
      final meta = metadata[globalKey];
      if (meta == null) continue;

      trackNodes.add(
        DownloadTreeNode(
          key: globalKey,
          title: meta.title ?? globalKey,
          type: DownloadNodeType.track,
          progress: download.progressPercent,
          status: download.status,
          metadata: meta,
          downloadProgress: download,
        ),
      );
    }
    if (trackNodes.isEmpty) continue;

    trackNodes.sort((a, b) {
      final byDisc = (a.metadata?.discNumber ?? 1).compareTo(b.metadata?.discNumber ?? 1);
      if (byDisc != 0) return byDisc;
      return (a.metadata?.trackNumber ?? 0).compareTo(b.metadata?.trackNumber ?? 0);
    });

    final albumProgress = trackNodes.map((e) => e.progress).reduce((a, b) => a + b) / trackNodes.length;
    final albumStatus = determineDownloadAggregateStatus(trackNodes.map((e) => e.status).toList());

    albums.add(
      DownloadTreeNode(
        key: albumKey,
        title: albumNodeTitle,
        type: DownloadNodeType.album,
        progress: albumProgress,
        status: albumStatus,
        children: trackNodes,
      ),
    );
  }

  final List<DownloadTreeNode> playlistNodes = [];
  for (final playlist in playlists) {
    final members = playlistMembers[playlist.key];
    if (members == null || members.isEmpty) continue;

    final children = <DownloadTreeNode>[];
    for (final entry in members) {
      final meta = metadata[entry.key];
      if (meta == null) continue;
      children.add(
        DownloadTreeNode(
          key: entry.key,
          title: meta.displayTitle,
          type: meta.isEpisode
              ? DownloadNodeType.episode
              : (meta.kind == MediaKind.track ? DownloadNodeType.track : DownloadNodeType.movie),
          progress: entry.value.progressPercent,
          status: entry.value.status,
          metadata: meta,
          downloadProgress: entry.value,
        ),
      );
    }
    if (children.isEmpty) continue;

    _sortNodesByStatusAndTitle(children);
    playlistNodes.add(
      DownloadTreeNode(
        key: playlist.key,
        title: playlist.title,
        type: DownloadNodeType.playlist,
        progress: children.map((c) => c.progress).reduce((a, b) => a + b) / children.length,
        status: determineDownloadAggregateStatus(children.map((c) => c.status).toList()),
        children: children,
      ),
    );
  }

  _sortNodesByStatusAndTitle(playlistNodes);
  _sortNodesByStatusAndTitle(shows);
  _sortNodesByStatusAndTitle(albums);
  _sortNodesByStatusAndTitle(movies);

  // Work in progress comes first whatever kind of thing it is. Sorting inside
  // each kind is not enough: concatenating movies, then shows, then albums
  // buried a downloading show under every finished movie. Partitioning rather
  // than sorting keeps the ordering already established within each kind.
  final ordered = [...playlistNodes, ...movies, ...shows, ...albums];
  return [...ordered.where((node) => node.isActive), ...ordered.where((node) => !node.isActive)];
}

/// Reduce child statuses to a container status, covering every
/// [DownloadStatus] value explicitly.
///
/// Active states take precedence (downloading > queued > paused > failed);
/// among purely terminal children, all-cancelled stays cancelled, all-completed
/// stays completed, and any other mix — completed next to cancelled, or a
/// child that is itself partial — is partial.
@visibleForTesting
DownloadStatus determineDownloadAggregateStatus(List<DownloadStatus> statuses) {
  if (statuses.isEmpty) return DownloadStatus.queued;

  if (statuses.any((s) => s == DownloadStatus.downloading)) {
    return DownloadStatus.downloading;
  }
  if (statuses.any((s) => s == DownloadStatus.queued)) {
    return DownloadStatus.queued;
  }
  if (statuses.any((s) => s == DownloadStatus.paused)) {
    return DownloadStatus.paused;
  }
  if (statuses.any((s) => s == DownloadStatus.failed)) {
    return DownloadStatus.failed;
  }

  // Only terminal outcomes remain: completed, cancelled, partial.
  if (statuses.every((s) => s == DownloadStatus.cancelled)) {
    return DownloadStatus.cancelled;
  }
  if (statuses.every((s) => s == DownloadStatus.completed)) {
    return DownloadStatus.completed;
  }
  return DownloadStatus.partial;
}

int _compareByStatus(DownloadStatus a, DownloadStatus b) {
  const statusOrder = {
    DownloadStatus.downloading: 0,
    DownloadStatus.queued: 1,
    DownloadStatus.paused: 2,
    DownloadStatus.completed: 3,
    DownloadStatus.failed: 4,
    DownloadStatus.cancelled: 5,
  };
  return (statusOrder[a] ?? 99).compareTo(statusOrder[b] ?? 99);
}

void _sortNodesByStatusAndTitle(List<DownloadTreeNode> nodes) {
  nodes.sort((a, b) {
    final statusCompare = _compareByStatus(a.status, b.status);
    if (statusCompare != 0) return statusCompare;
    return a.title.compareTo(b.title);
  });
}
