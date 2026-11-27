# Merging Plezy upstream into Bask

This records the one-off merge of 680 upstream commits, and the decisions it
forced. It is history, not instructions: the merge is done.

## Why it was expensive

The merge base is the fork point `b444741ca9`, still an ancestor of `main`, so
every upstream commit since was mergeable in principle. What made it expensive
is that this fork renamed almost everything: the Dart package, the Android
package (`com.edde746.plezy` -> `com.inknironapps.bask`), the Kotlin source
directory and every user-facing string. Git sees a rename as a rename, so
upstream edits to a renamed file arrive as conflicts even where the two sides
never disagreed. The first attempt reported 324 conflicting paths.

## How most of them were removed

A three-way merge agrees wherever a line is identical in base and theirs.
Applying this fork's rename to *both* the base and the upstream side restores
that for rename-only churn, and it is safe in the right direction: the
transform cancels out wherever upstream did not touch the line, so a wrong rule
can only produce a conflict, never a silent wrong answer.

    com.edde746.plezy -> com.inknironapps.bask
    com/edde746/plezy -> com/inknironapps/bask
    package:plezy/    -> package:bask/
    Plezy             -> Bask
    plezy             -> bask        (whole word only; never com.plezy/..., *.plezy.app
                                      or plezy_downloads, which this fork kept)

That alone resolved 110 files. It is still a blunt instrument, and it did
overreach twice: it rewrote `edde746/flutter-plezy` in the Windows engine
installer, and it rewrote the Android deep-link scheme to `bask://` when
`lib/services/deep_links/deep_link.dart` still answers to `plezy://`. Both were
put back by hand. **Anything taken from the upstream side needs the same check:
a URL, channel name, scheme or storage key that says `bask` where it used to
say `plezy` is a bug.**

## What this fork kept, and what it took

Kept (upstream's version was declined, and its callers were adjusted):

- **The download engine.** `DownloadManagerService`, `DownloadProvider`,
  `DownloadTreeView` and the Downloads screen stay as this fork has them: the
  stall watchdog, the metered-data budget, download windows, SAF ownership and
  the reclaim pass are all local work and all interleaved. The cost is
  upstream's stacked multi-part downloads and its download-collections feature,
  which are not here; `downloads_options.dart`, `downloads_folder_actions.dart`
  and the offline collection context menu were dropped with them. The
  `DownloadCollections` tables are still created by the migration, unused, so
  the feature can be picked up later without another schema step.
- **The theme system.** `ThemePalette` — a colour identity layered over
  light/dark/OLED — stays, and `ThemeMode` stays at four values. Upstream's
  supporter-gated preset themes, its custom-theme editor and its alternate app
  icons are gone, along with `lib/services/supporter/**` and the 24 icon sets:
  nothing in Bask is gated behind a purchase, and the icon art is Plezy's.
- **The source resolver's rule that a downloaded copy always wins**, with
  upstream's narrower `downloadOutranksQuality` parameter accepted so its
  callers compile.
- Self-hosted defaults: no log-upload or poster-upload endpoint unless a build
  defines one.

Taken from upstream:

- **`monoTheme` and `MonoPalette`.** Upstream's palette object is a better base
  than this fork's booleans, so `ThemePalette.monoFor(dark:, oled:)` now builds
  one. That also made upstream's three presets portable: **ember, glacier and
  paper are new `ThemePalette` values**, carrying upstream's tuned colours for
  the brightness they were drawn for, with the existing hue recipe covering the
  other one. The mode still owns brightness, so paper on a dark theme is a teal
  accent on a dark page rather than a forced light theme.
- **The native build.** Upstream replaced the in-project `:libmpv` module with
  a prebuilt `mpv-android` AAR, so `mpv-build.lock.json`,
  `scripts/set_native_revision.sh`, `android/app/build.gradle.kts` and the six
  Swift `Package.resolved` files came over wholesale.
- **`AudioChannelLimit`** in place of the stereo-downmix boolean, with its
  legacy migration, because upstream had already wired it through the player
  layer. The dialogue boost and the loudness filter chain stay this fork's —
  and Android now uses upstream's cheaper compressor/limiter chain instead of
  `loudnorm`, which was making video frames late on a 32-bit TV box (#2654).
- The rewritten Watch Together, the declarative settings-effects registry,
  person search results, the `_DownloadButtonSpec` download button (with this
  fork's "manage the sync rule while it downloads" behaviour re-applied), the
  IPv4-before-IPv6 connection ordering, and upstream's launcher-activity
  design: the real activity is `.BaskActivity` with `.MainActivity` kept as an
  alias so existing shortcuts and TV favourites still resolve.

## The database

Both sides added migrations from schema 22. This fork had spent 23 and 24;
upstream had spent 23, 24 and 25 on different things. Upstream's three are
renumbered 25 to 27 and run above both schemes, so a Bask database sitting at
24 still gets them — every step ignores "already exists", so one that somehow
has them is left alone. Schema version is 27.

## Verifying it

`flutter analyze` is clean across `lib` and `test`, after `scripts/codegen.sh`.
The suite runs in CI; this fork does not build locally.

## What a real device found

The suite cannot compile Kotlin and cannot open a database that predates the
merge, so two whole classes of damage were invisible until an APK was built and
installed. The "Bask test build" workflow exists for exactly this: it signs with
the release keystore so the APK replaces an existing install rather than
demanding an uninstall that would take the test database with it.

**The Android build did not compile.** Four regressions, all of them the merge
taking upstream's side of a region this fork had changed: a dropped
`buildFeatures { buildConfig = true }` (upstream never reads BuildConfig,
because its namespace and applicationId are the same string, and this fork's
are not), an import of `com.edde746.plezy.shared.PlayerDebugLog` that the
rename pass left alone because the neighbouring `com.edde746.mpv` imports are
real, `BaskActivity` wired to an `AppIconChannel` whose class, manifest aliases,
icon resources and Dart side all stayed upstream, and `WatchNextProvider` still
matching `plezy://play` after the scheme became `bask`. Fixed in
`fix(android): repair what the upstream merge broke in the native build`.

**The migration is good.** On a Pixel with a real pre-merge database, 25, 26 and
27 ran in order and the database was ready in 472ms. Resume positions survived
(Continue Watching came back with the right episodes and the right progress),
and so did the downloads: 79.44 GB, a 17-of-17 collection and a loose film, all
listed correctly on a Downloads screen whose tables the merge had just created.

**Artwork did not load, and the URL builders were never the problem.** Every
image 401d on `/photo/:/transcode?...&X-Plex-Token=` with an empty token --
empty in the query and again inside the encoded `url=` -- while API calls on
the same client and server answered 200.

The cause was in the artwork cache, not in any URL builder.
`PlexImageCacheManager.getFileStream` deliberately hands the cache a redacted
copy of the URL, so the token does not end up in plaintext cache metadata that
outlives sign-out, and `_ArtworkCredentialInterceptor` restores the real URL
before the download leaves. Two constructors existed, and only the
`forTesting` one registered that interceptor; the app's own did not. So the app
downloaded the redacted URL, which is precisely a request with a blank token in
both places, and the server refused it. Nothing caught it: the tests drove the
constructor that had the interceptor, and the builders, which were correct,
had nothing to report -- their diagnostics never fired once.

Fixed in `fix(images): restore the token the artwork cache strips before
downloading`: one constructor, which always registers the interceptor and which
the tests drive, plus a test that fails without it. The bug arrived with
upstream's own `fix(images): keep server tokens out of the artwork cache
metadata`, so it is not in any released version of this fork.

With that cleared, nothing known blocks the merge.

## Upstream screens the merge dropped

The merge kept upstream's models, helpers, database columns and tests while
resolving several screens to this fork's side, which left those helpers
orphaned and the features gone. `check-unused-files` and `check-unused-code`
are what found them, and they only ran once the branch reached a gated branch:
`merge-upstream` has no gate of its own.

**Downloads grouping, sort and filter** — restored. `downloads_options.dart`
(the whole options surface) had been dropped, orphaning `downloads_filter.dart`,
`downloads_sort_options.dart` and `downloads_collection_grouping.dart`, while
the `downloaded_media.libraryId` column, the `download_collections` table,
`media_item_sort.dart`'s download keys and every i18n string survived. The
options UI is back and wired into both grid tabs: sort, filters and grouping by
shows, seasons, episodes or library, with the chips bar on desktop and TV and
the sheet on mobile.

Collections grouping is deliberately not offered yet. Folding is ported and
tested in `DownloadProvider.groupDownloadsByCollection`, but opening a folder
needs three more pieces the merge dropped: the offline mode of
`collection_detail_screen.dart` (91 lines, and this fork has its own changes in
that file to keep), `lib/utils/downloads_folder_actions.dart`, and
`syncDownloadCollections` to fill `download_collections` when a server
connects. Without the last one no folder would ever appear, so a partial port
would only look finished.

**The theme screens** — not restored. `custom_theme_editor_screen.dart` and
`theme_settings_screen.dart` are both gone from `lib/screens/settings/`, while
`settings_service.dart` still carries the custom-theme keys. The orphan this
left behind, `monoThemeUncached`, has been removed because nothing in this tree
can call it; the function is one line and comes back with the editor. Whether
the Supporter theme editor should return is a product decision, not a merge
repair.
