import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../models/download_models.dart';
import '../../services/offline_playlist_queue.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/download_status_icon.dart';
import '../../widgets/download_tree_view.dart';

/// Playlists whose contents are on the device, with the transport for playing
/// them.
///
/// Separate from the manage list on purpose: that one is about the state of
/// transfers — pause, retry, delete — and playback is a different intent that
/// was competing with those controls for the same dense row.
class DownloadedPlaylistsTab extends StatefulWidget {
  final List<DownloadPlaylistGroup> playlists;
  final Map<String, MediaItem> metadata;
  final Map<String, DownloadProgress> downloads;
  final void Function(DownloadPlaylistGroup playlist, {required bool shuffle}) onPlay;
  final bool suppressAutoFocus;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;

  const DownloadedPlaylistsTab({
    super.key,
    required this.playlists,
    required this.metadata,
    required this.downloads,
    required this.onPlay,
    this.suppressAutoFocus = false,
    this.onNavigateLeft,
    this.onBack,
  });

  @override
  State<DownloadedPlaylistsTab> createState() => _DownloadedPlaylistsTabState();
}

class _DownloadedPlaylistsTabState extends State<DownloadedPlaylistsTab> {
  final Set<String> _expanded = {};

  void _toggle(String key) {
    setState(() => _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key));
  }

  /// The playlist's items in list order, whatever state each one is in.
  ///
  /// Not filtered to finished downloads the way the play queue is: seeing what
  /// is still coming is the point of opening the list.
  List<({String key, MediaItem? item, DownloadStatus? status})> _contentsOf(DownloadPlaylistGroup playlist) => [
    for (final key in playlist.memberKeys)
      (key: key, item: widget.metadata[key], status: widget.downloads[key]?.status),
  ];

  @override
  Widget build(BuildContext context) {
    if (widget.playlists.isEmpty) {
      return Center(child: Text(t.downloads.noDownloadsTree));
    }

    // One flat list so the rows scroll as a unit rather than nesting scrollables.
    final rows = <Widget>[];
    for (var index = 0; index < widget.playlists.length; index++) {
      final playlist = widget.playlists[index];
      final playableCount = OfflinePlaylistQueue.playableMembers(
        memberKeys: playlist.memberKeys,
        metadata: widget.metadata,
        downloads: widget.downloads,
      ).length;

      rows.add(
        _PlaylistRow(
          playlist: playlist,
          playableCount: playableCount,
          totalCount: playlist.memberKeys.length,
          isExpanded: _expanded.contains(playlist.key),
          onToggleExpanded: () => _toggle(playlist.key),
          onPlay: widget.onPlay,
          autofocus: index == 0 && !widget.suppressAutoFocus,
          onNavigateLeft: widget.onNavigateLeft,
          onBack: widget.onBack,
        ),
      );

      if (_expanded.contains(playlist.key)) {
        rows.addAll(_contentsOf(playlist).map((entry) => _PlaylistItemRow(entry: entry)));
      }
    }

    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: rows);
  }
}

class _PlaylistRow extends StatelessWidget {
  final DownloadPlaylistGroup playlist;
  final int playableCount;
  final int totalCount;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;
  final void Function(DownloadPlaylistGroup playlist, {required bool shuffle}) onPlay;
  final bool autofocus;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;

  const _PlaylistRow({
    required this.playlist,
    required this.playableCount,
    required this.totalCount,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.onPlay,
    required this.autofocus,
    this.onNavigateLeft,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canPlay = playableCount > 0;
    // Naming both numbers while they differ says the list is still filling,
    // which a bare "3 downloaded" on a ten-item playlist does not.
    final subtitle = playableCount == totalCount
        ? t.downloads.playlistItemCount(count: playableCount)
        : t.downloads.playlistItemCountOf(done: playableCount, total: totalCount);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: FocusableWrapper(
        autofocus: autofocus,
        onSelect: onToggleExpanded,
        onNavigateLeft: onNavigateLeft,
        onBack: onBack,
        borderRadius: 12,
        disableScale: true,
        useBackgroundFocus: true,
        child: ListTile(
          onTap: onToggleExpanded,
          leading: AppIcon(isExpanded ? Symbols.expand_more_rounded : Symbols.chevron_right_rounded, fill: 1, size: 24),
          title: Text(playlist.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1),
                tooltip: t.common.play,
                onPressed: canPlay ? () => onPlay(playlist, shuffle: false) : null,
              ),
              IconButton(
                icon: const AppIcon(Symbols.shuffle_rounded, fill: 1),
                tooltip: t.common.shuffle,
                onPressed: canPlay ? () => onPlay(playlist, shuffle: true) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One item inside an expanded playlist, with the state of its download.
class _PlaylistItemRow extends StatelessWidget {
  final ({String key, MediaItem? item, DownloadStatus? status}) entry;

  const _PlaylistItemRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = entry.item?.displayTitle;
    final status = entry.status;

    return Padding(
      padding: const EdgeInsets.only(left: 40, right: 16, top: 2, bottom: 2),
      child: Row(
        children: [
          // A member with no download row at all is one the rule knows about but
          // has not started; the rest carry their real state.
          if (status != null)
            DownloadStatusIcon(status: status, size: 18)
          else
            AppIcon(Symbols.schedule_rounded, fill: 1, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title == null || title.isEmpty ? entry.key : title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
