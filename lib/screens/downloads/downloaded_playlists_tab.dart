import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../models/download_models.dart';
import '../../services/offline_playlist_queue.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/download_tree_view.dart';
import '../../focus/focusable_wrapper.dart';

/// Playlists whose contents are on the device, with the transport for playing
/// them.
///
/// Separate from the manage list on purpose: that one is about the state of
/// transfers — pause, retry, delete — and playback is a different intent that
/// was competing with those controls for the same dense row.
class DownloadedPlaylistsTab extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (playlists.isEmpty) {
      return Center(child: Text(t.downloads.noDownloadsTree));
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: playlists.length,
      itemBuilder: (context, index) => _PlaylistRow(
        playlist: playlists[index],
        // Counts only what can actually be played, so the row does not promise
        // items that are still downloading.
        playableCount: OfflinePlaylistQueue.playableMembers(
          memberKeys: playlists[index].memberKeys,
          metadata: metadata,
          downloads: downloads,
        ).length,
        onPlay: onPlay,
        autofocus: index == 0 && !suppressAutoFocus,
        onNavigateLeft: onNavigateLeft,
        onBack: onBack,
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  final DownloadPlaylistGroup playlist;
  final int playableCount;
  final void Function(DownloadPlaylistGroup playlist, {required bool shuffle}) onPlay;
  final bool autofocus;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onBack;

  const _PlaylistRow({
    required this.playlist,
    required this.playableCount,
    required this.onPlay,
    required this.autofocus,
    this.onNavigateLeft,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canPlay = playableCount > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: FocusableWrapper(
        autofocus: autofocus,
        onSelect: canPlay ? () => onPlay(playlist, shuffle: false) : null,
        onNavigateLeft: onNavigateLeft,
        onBack: onBack,
        borderRadius: 12,
        disableScale: true,
        useBackgroundFocus: true,
        child: ListTile(
          leading: const AppIcon(Symbols.playlist_play_rounded, fill: 1, size: 28),
          title: Text(playlist.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            t.downloads.playlistItemCount(count: playableCount),
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
