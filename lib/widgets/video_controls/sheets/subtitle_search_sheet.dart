import 'dart:async';
import '../../../media/ids.dart';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_button.dart';
import '../../../focus/focusable_text_field.dart';
import '../../../focus/input_mode_tracker.dart';
import '../../../i18n/strings.g.dart';
import '../../../mixins/controller_disposer_mixin.dart';
import '../../../models/plex/plex_subtitle_search_result.dart';
import '../../../services/settings_service.dart';
import '../../../utils/language_codes.dart';
import '../../../utils/provider_extensions.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import 'package:provider/provider.dart';

import '../../../providers/account_preferences_controller.dart';
import '../../../widgets/overlay_sheet.dart';
import '../../../widgets/pill_input_decoration.dart';
import 'base_video_control_sheet.dart';
import '../../loading_indicator_box.dart';
import '../models/track_controls_state.dart';

/// The language to search subtitles in: the saved choice, else the account's
/// preferred subtitle language, else the system language, else English.
///
/// Used by the auto-fetch path too, which needs the same answer the sheet
/// would give — searching in a language the user does not read would make its
/// one automatic action useless.
///
/// [accountLanguageCode] is the server-stored
/// [AccountPreferenceKey.preferredSubtitleLanguage], and it sits above the
/// system locale because it is a statement about subtitles specifically: a
/// device in English owned by someone who reads Spanish subtitles used to
/// search English, and the only way to say otherwise was to open the sheet
/// and pick a language, which is also the only thing that ever wrote
/// [SettingsService.subtitleSearchLanguage]. The saved choice still wins,
/// since it was made for this purpose on this device.
String resolveSubtitleSearchLanguageCode({
  String? savedLanguageCode,
  String? accountLanguageCode,
  required Locale systemLocale,
}) {
  return LanguageCodes.getIso6391Code(savedLanguageCode ?? '') ??
      LanguageCodes.getIso6391Code(accountLanguageCode ?? '') ??
      LanguageCodes.getIso6391Code(systemLocale.languageCode) ??
      'en';
}

/// Hash matches first, then by the provider's score.
///
/// `perfectMatch` is OpenSubtitles reporting that the subtitle was timed
/// against a file with this file's hash, so it cannot drift — which a
/// high-scoring subtitle for another release certainly can, by 4% if the two
/// releases differ in frame rate. The provider does not return them in that
/// order, so an exact match could sit below worse results with only a star to
/// distinguish it.
@visibleForTesting
List<PlexSubtitleSearchResult> rankSubtitleResults(List<PlexSubtitleSearchResult> results) {
  final ranked = List<PlexSubtitleSearchResult>.of(results);
  ranked.sort((a, b) {
    if (a.perfectMatch != b.perfectMatch) return a.perfectMatch ? -1 : 1;
    return (b.score ?? 0).compareTo(a.score ?? 0);
  });
  return ranked;
}

class SubtitleSearchSheet extends StatefulWidget {
  final String ratingKey;
  final String serverId;
  final String? mediaTitle;
  final Future<SubtitleDownloadApplyOutcome> Function({required String serverId, required String ratingKey})?
  onSubtitleDownloaded;

  const SubtitleSearchSheet({
    super.key,
    required this.ratingKey,
    required this.serverId,
    this.mediaTitle,
    this.onSubtitleDownloaded,
  });

  @override
  State<SubtitleSearchSheet> createState() => _SubtitleSearchSheetState();
}

class _SubtitleSearchSheetState extends State<SubtitleSearchSheet> with ControllerDisposerMixin {
  String _languageCode = 'en';
  String _languageName = 'English';
  late final _titleController = createTextEditingController();
  final _languageFocusNode = FocusNode(debugLabel: 'SubtitleSearch_language');
  final _titleFocusNode = FocusNode(debugLabel: 'SubtitleSearch_title');
  final _firstResultFocusNode = FocusNode(debugLabel: 'SubtitleSearch_firstResult');
  Timer? _debounceTimer;

  List<PlexSubtitleSearchResult>? _results;
  bool _isSearching = false;
  String? _error;
  String? _downloadingKey;
  int _searchGeneration = 0;

  bool _showLanguagePicker = false;

  @override
  void initState() {
    super.initState();
    _initDefaultLanguage();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  void _initDefaultLanguage() {
    final code = resolveSubtitleSearchLanguageCode(
      savedLanguageCode: SettingsService.instanceOrNull?.read(SettingsService.subtitleSearchLanguage),
      accountLanguageCode: context
          .read<AccountPreferencesController?>()
          ?.activePreferences
          ?.preferredSubtitleLanguageCode1,
      systemLocale: WidgetsBinding.instance.platformDispatcher.locale,
    );
    final name = LanguageCodes.getLanguageName(code);
    if (name == null) return;
    _languageCode = code;
    _languageName = name;
  }

  @override
  void dispose() {
    ++_searchGeneration;
    _debounceTimer?.cancel();
    _languageFocusNode.dispose();
    _titleFocusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (!mounted) return;
    final generation = ++_searchGeneration;
    setState(() {
      _isSearching = true;
      _error = null;
    });

    try {
      final client = context.tryGetPlexClientForServer(ServerId(widget.serverId));
      if (client == null) {
        if (!mounted || generation != _searchGeneration) return;
        setState(() => _isSearching = false);
        return;
      }
      final title = _titleController.text.trim();
      final language = _languageCode;
      final results = await client.searchSubtitles(
        widget.ratingKey,
        language: language,
        title: title.isEmpty ? null : title,
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = rankSubtitleResults(results);
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _error = e.toString();
        _isSearching = false;
      });
    }
  }

  void _onTitleChanged(String _) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), _search);
  }

  void _showLanguagePickerView() {
    setState(() => _showLanguagePicker = true);
    OverlaySheetController.of(context).refocus();
  }

  void _hideLanguagePickerView() {
    setState(() => _showLanguagePicker = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _languageFocusNode.requestFocus();
    });
  }

  void _focusFirstResult() {
    if (_results != null && _results!.isNotEmpty && !_isSearching && _error == null) {
      _firstResultFocusNode.requestFocus();
    }
  }

  Future<void> _submitSearchAndFocusFirstResult() async {
    _debounceTimer?.cancel();
    await _search();
    if (!mounted || !InputModeTracker.isKeyboardMode(context, listen: false)) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusFirstResult();
    });
  }

  void _onLanguageSelected(String code, String name) {
    _debounceTimer?.cancel();
    setState(() {
      _languageCode = code;
      _languageName = name;
      _showLanguagePicker = false;
    });
    final settings = SettingsService.instanceOrNull;
    if (settings != null) {
      unawaited(settings.write(SettingsService.subtitleSearchLanguage, code));
    }
    OverlaySheetController.of(context).refocus();
    _search();
  }

  Future<void> _downloadSubtitle(PlexSubtitleSearchResult result) async {
    if (_downloadingKey != null) return;
    setState(() => _downloadingKey = result.key);

    try {
      final client = context.tryGetPlexClientForServer(ServerId(widget.serverId));
      if (client == null) {
        if (!mounted) return;
        setState(() => _downloadingKey = null);
        return;
      }
      final success = await client.downloadSubtitle(
        widget.ratingKey,
        key: result.key,
        codec: result.codec ?? 'srt',
        language: result.languageCode ?? _languageCode,
        hearingImpaired: result.hearingImpaired,
        forced: result.forced,
        providerTitle: result.providerTitle ?? '',
      );

      if (!mounted) return;

      if (success) {
        final outcome =
            await widget.onSubtitleDownloaded?.call(serverId: widget.serverId, ratingKey: widget.ratingKey) ??
            SubtitleDownloadApplyOutcome.unavailable;
        if (!mounted) return;
        if (outcome == SubtitleDownloadApplyOutcome.applied) {
          showSuccessSnackBar(context, t.videoControls.subtitleDownloaded);
          OverlaySheetController.of(context).close();
        } else {
          showErrorSnackBar(context, t.videoControls.subtitleDownloadedNotApplied);
          setState(() => _downloadingKey = null);
        }
      } else {
        showErrorSnackBar(context, t.videoControls.subtitleDownloadFailed);
        setState(() => _downloadingKey = null);
      }
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, t.videoControls.subtitleDownloadFailed);
      setState(() => _downloadingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showLanguagePicker) {
      return _LanguagePickerView(
        currentCode: _languageCode,
        onSelected: _onLanguageSelected,
        onBack: _hideLanguagePickerView,
      );
    }

    final fillColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    final hasResults = _results != null && _results!.isNotEmpty && !_isSearching && _error == null;

    return BaseVideoControlSheet(
      title: t.videoControls.searchSubtitles,
      icon: Symbols.search_rounded,
      onBack: () => OverlaySheetController.of(context).pop(),
      // Deliberately fills the sheet's height cap instead of hugging content.
      // Overlay sheets are bottom-anchored, so a content-driven height would
      // move the search field on every state transition — spinner, results,
      // error, empty — while the user is still typing in it. A search surface
      // needs a stable frame; the results list normally fills it anyway.
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FocusableButton(
                  focusNode: _languageFocusNode,
                  onPressed: _showLanguagePickerView,
                  onNavigateRight: _titleFocusNode.requestFocus,
                  onNavigateDown: hasResults ? _focusFirstResult : null,
                  autoScroll: false,
                  child: Material(
                    color: fillColor,
                    borderRadius: pillInputRadius,
                    child: InkWell(
                      borderRadius: pillInputRadius,
                      canRequestFocus: false,
                      onTap: _showLanguagePickerView,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          mainAxisSize: .min,
                          children: [
                            Text(_languageName),
                            const SizedBox(width: 2),
                            const AppIcon(Symbols.arrow_drop_down_rounded, size: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FocusableTextField(
                    controller: _titleController,
                    focusNode: _titleFocusNode,
                    tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
                    decoration: pillInputDecoration(
                      context,
                      hintText: widget.mediaTitle ?? t.metadataEdit.title,
                      prefixIcon: const AppIcon(Symbols.search_rounded, size: 20),
                    ),
                    onChanged: _onTitleChanged,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => unawaited(_submitSearchAndFocusFirstResult()),
                    onSelect: () => unawaited(_submitSearchAndFocusFirstResult()),
                    onNavigateLeft: _languageFocusNode.requestFocus,
                    onNavigateDown: hasResults ? _focusFirstResult : null,
                  ),
                ),
              ],
            ),
          ),
          // One tap for the common case. A hash match is timed against this
          // exact file, so there is nothing to choose between it and the rest
          // — reading a list to find the starred row is work the app can do.
          if (_bestMatch case final best?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: FocusableButton(
                onPressed: _downloadingKey == null ? () => unawaited(_downloadSubtitle(best)) : null,
                autoScroll: false,
                child: Material(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: pillInputRadius,
                  child: InkWell(
                    borderRadius: pillInputRadius,
                    canRequestFocus: false,
                    onTap: _downloadingKey == null ? () => unawaited(_downloadSubtitle(best)) : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        mainAxisSize: .min,
                        spacing: 8,
                        children: [
                          const AppIcon(Symbols.star_rounded, fill: 1, size: 18),
                          Text(t.videoControls.subtitleBestMatch),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  /// The hash-matched result, if the provider returned one.
  ///
  /// `_ranked` puts it first, so this is a check of the head rather than a
  /// scan — and null when the provider has nothing timed to this file, which
  /// is when the list is worth reading.
  PlexSubtitleSearchResult? get _bestMatch {
    final results = _results;
    if (results == null || results.isEmpty) return null;
    final first = results.first;
    return first.perfectMatch ? first : null;
  }

  Widget _buildResults() {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
    }

    if (_results == null) {
      return const SizedBox.shrink();
    }

    if (_results!.isEmpty) {
      return Center(
        child: Text(
          t.videoControls.noSubtitlesFound,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      itemCount: _results!.length,
      itemBuilder: (context, index) {
        final result = _results![index];
        final isDownloading = _downloadingKey == result.key;
        final colorScheme = Theme.of(context).colorScheme;

        Widget? trailing;
        if (isDownloading) {
          trailing = const LoadingIndicatorBox(size: 20);
        } else {
          final trailingChildren = <Widget>[];
          if (result.perfectMatch) {
            trailingChildren.add(const AppIcon(Symbols.star_rounded, fill: 1, color: Color(0xFFCC7B19), size: 16));
          }
          if (result.score != null) {
            trailingChildren.add(
              Text(
                result.score!.toInt().toString(),
                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
              ),
            );
          }
          if (trailingChildren.isNotEmpty) {
            trailing = Row(mainAxisSize: .min, spacing: 4, children: trailingChildren);
          }
        }

        return FocusableListTile(
          focusNode: index == 0 ? _firstResultFocusNode : null,
          title: Text(result.title ?? result.displayTitle ?? t.common.unknown, maxLines: 1, overflow: .ellipsis),
          subtitle: Text(
            result.displayTitle ?? '',
            maxLines: 1,
            overflow: .ellipsis,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          trailing: trailing,
          onTap: isDownloading ? null : () => _downloadSubtitle(result),
        );
      },
    );
  }
}

class _LanguagePickerView extends StatefulWidget {
  final String currentCode;
  final void Function(String code, String name) onSelected;
  final VoidCallback onBack;

  const _LanguagePickerView({required this.currentCode, required this.onSelected, required this.onBack});

  @override
  State<_LanguagePickerView> createState() => _LanguagePickerViewState();
}

class _LanguagePickerViewState extends State<_LanguagePickerView> with ControllerDisposerMixin {
  late final _filterController = createTextEditingController();
  final _filterFocusNode = FocusNode(debugLabel: 'SubtitleLanguage_filter');
  final _firstLanguageFocusNode = FocusNode(debugLabel: 'SubtitleLanguage_firstResult');
  late List<({String code, String name})> _allLanguages;
  List<({String code, String name})> _filteredLanguages = [];

  @override
  void initState() {
    super.initState();
    _allLanguages = LanguageCodes.getAllLanguages();
    _filteredLanguages = _allLanguages;
  }

  @override
  void dispose() {
    _filterFocusNode.dispose();
    _firstLanguageFocusNode.dispose();
    super.dispose();
  }

  void _focusFirstLanguage() {
    if (_filteredLanguages.isNotEmpty) {
      _firstLanguageFocusNode.requestFocus();
    }
  }

  void _focusFirstLanguageAfterSubmit() {
    if (!InputModeTracker.isKeyboardMode(context)) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusFirstLanguage();
    });
  }

  void _onFilterChanged(String query) {
    final lower = query.toLowerCase();
    setState(() {
      if (lower.isEmpty) {
        _filteredLanguages = _allLanguages;
      } else {
        _filteredLanguages = _allLanguages.where((l) {
          return l.name.toLowerCase().contains(lower) || l.code.toLowerCase().contains(lower);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BaseVideoControlSheet(
      title: t.videoControls.language,
      icon: Symbols.language_rounded,
      onBack: widget.onBack,
      // Fills the height cap for the same reason as the search body: the filter
      // field is autofocused and refilters on every keystroke, so a
      // content-driven height would slide the field the user is typing in.
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FocusableTextField(
              controller: _filterController,
              focusNode: _filterFocusNode,
              tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
              autofocus: true,
              decoration: pillInputDecoration(
                context,
                hintText: t.videoControls.searchLanguages,
                prefixIcon: const AppIcon(Symbols.search_rounded, size: 20),
              ),
              onChanged: _onFilterChanged,
              onSubmitted: (_) => _focusFirstLanguageAfterSubmit(),
              onSelect: _focusFirstLanguageAfterSubmit,
              onNavigateDown: _filteredLanguages.isNotEmpty ? _focusFirstLanguage : null,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _filteredLanguages.length,
              itemBuilder: (context, index) {
                final lang = _filteredLanguages[index];
                final isSelected = lang.code == widget.currentCode;
                return FocusableListTile(
                  focusNode: index == 0 ? _firstLanguageFocusNode : null,
                  title: Text(
                    lang.name,
                    style: TextStyle(color: isSelected ? Theme.of(context).colorScheme.primary : null),
                  ),
                  trailing: isSelected
                      ? AppIcon(Symbols.check_rounded, fill: 1, color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () => widget.onSelected(lang.code, lang.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
