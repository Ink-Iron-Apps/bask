import '../database/app_database.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';

/// One show the device should keep the next episodes of.
class AutoDownloadTarget {
  const AutoDownloadTarget({required this.serverId, required this.showId, this.title});

  final ServerId serverId;
  final String showId;
  final String? title;

  @override
  bool operator ==(Object other) => other is AutoDownloadTarget && other.serverId == serverId && other.showId == showId;

  @override
  int get hashCode => Object.hash(serverId, showId);

  @override
  String toString() => 'AutoDownloadTarget(${title ?? showId})';
}

/// What has to change for the managed rules to match [AutoDownloadTarget]s.
class AutoDownloadPlan {
  const AutoDownloadPlan({required this.create, required this.remove});

  final List<AutoDownloadTarget> create;

  /// Profile-scoped global keys of managed rules that no longer apply.
  final List<String> remove;

  bool get isEmpty => create.isEmpty && remove.isEmpty;
}

/// Decides which shows the device keeps episodes of, without being asked.
///
/// A sync rule already keeps N episodes of a show downloaded, but only for a
/// show the user went and set one up for — so the answer to "is the next
/// episode on my phone" is yes for the shows they remembered and no for the
/// one they started last night. What they are watching is something the
/// server already knows: Continue Watching is exactly that list.
///
/// Everything here is a pure decision over data the caller fetched, so the
/// rules are testable without a server and the cost of the fetch stays
/// visible at the call site.
class AutoDownloadPlanner {
  AutoDownloadPlanner._();

  /// How many shows may hold managed rules at once.
  ///
  /// A bound rather than a setting: the point is the handful of things
  /// actually in flight, and Continue Watching on a shared server can be long.
  /// The storage budget is the backstop for size, this one is for restraint.
  static const int maxShows = 5;

  /// The shows behind a Continue Watching list, most recent first.
  ///
  /// Only episodes count: a film has no next episode to hold, and a show is
  /// named once however many of its episodes are in the list.
  static List<AutoDownloadTarget> showsInProgress(Iterable<MediaItem> continueWatching, {int limit = maxShows}) {
    final seen = <AutoDownloadTarget>{};
    final targets = <AutoDownloadTarget>[];

    for (final item in continueWatching) {
      if (!item.isEpisode) continue;
      final showId = item.grandparentId;
      final serverId = item.serverId;
      if (showId == null || showId.isEmpty || serverId == null || serverId.isEmpty) continue;

      final target = AutoDownloadTarget(serverId: ServerId(serverId), showId: showId, title: item.grandparentTitle);
      if (!seen.add(target)) continue;
      targets.add(target);
      if (targets.length >= limit) break;
    }

    return targets;
  }

  /// The difference between what should be managed and what is.
  ///
  /// [keyFor] builds the profile-scoped global key a rule is stored under, so
  /// this stays independent of how keys are composed.
  ///
  /// A target that already has a rule of any kind is left alone: a rule the
  /// user made for the same show is theirs, and replacing it with a managed
  /// one would quietly change what they chose to keep.
  static AutoDownloadPlan reconcile({
    required List<AutoDownloadTarget> targets,
    required Iterable<SyncRuleItem> existingRules,
    required String Function(ServerId serverId, String ratingKey) keyFor,
  }) {
    final existingByKey = {for (final rule in existingRules) rule.globalKey: rule};
    final wantedKeys = <String>{};
    final create = <AutoDownloadTarget>[];

    for (final target in targets) {
      final key = keyFor(target.serverId, target.showId);
      wantedKeys.add(key);
      final existing = existingByKey[key];
      if (existing == null) {
        create.add(target);
      }
    }

    final remove = [
      for (final rule in existingRules)
        if (rule.managed && !wantedKeys.contains(rule.globalKey)) rule.globalKey,
    ];

    return AutoDownloadPlan(create: create, remove: remove);
  }
}
