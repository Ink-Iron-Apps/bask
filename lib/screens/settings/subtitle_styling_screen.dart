import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/settings_service.dart';
import '../../utils/language_codes.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import 'settings_utils.dart';

/// Every ISO 639-1 language, plus the automatic choice, built once:
/// [LanguageCodes.getAllLanguages] allocates and sorts a fresh copy per call
/// and the page rebuilds after every write. The names come from the generated
/// ISO table rather than translations, so caching survives a locale change.
final _searchLanguageOptions = <DialogOption<String?>>[
  DialogOption(value: null, title: t.settings.subtitleSearchLanguageAutomatic),
  for (final language in LanguageCodes.getAllLanguages()) DialogOption(value: language.code, title: language.name),
];

class SubtitleStylingScreen extends StatelessWidget {
  const SubtitleStylingScreen({super.key});

  String _assOverrideLabel(SubAssOverride value) {
    return switch (value) {
      SubAssOverride.no => t.common.no,
      SubAssOverride.yes => t.common.yes,
      SubAssOverride.scale => t.subtitlingStyling.overrideScale,
      SubAssOverride.force => t.subtitlingStyling.overrideForce,
      SubAssOverride.strip => t.subtitlingStyling.overrideStrip,
    };
  }

  String _formatPosition(int value) {
    if (value == 0) return t.subtitlingStyling.positionTop;
    if (value == 100) return t.subtitlingStyling.positionBottom;
    return '$value%';
  }

  String _renderResolutionLabel(SubtitleRenderResolution value) {
    return switch (value) {
      SubtitleRenderResolution.screen => t.subtitlingStyling.renderResolutionScreen,
      SubtitleRenderResolution.video => t.subtitlingStyling.renderResolutionVideo,
      SubtitleRenderResolution.threeQuarter => '¾',
      SubtitleRenderResolution.half => '½',
      SubtitleRenderResolution.third => '⅓',
      SubtitleRenderResolution.quarter => '¼',
    };
  }

  String _rateCorrectionLabel(SubtitleRateCorrection value) => switch (value) {
    SubtitleRateCorrection.off => t.settings.subtitleRateCorrectionOff,
    SubtitleRateCorrection.certain => t.settings.subtitleRateCorrectionCertain,
    SubtitleRateCorrection.always => t.settings.subtitleRateCorrectionAlways,
  };

  String _rateCorrectionDescription(SubtitleRateCorrection value) => switch (value) {
    SubtitleRateCorrection.off => t.settings.subtitleRateCorrectionOffDescription,
    SubtitleRateCorrection.certain => t.settings.subtitleRateCorrectionCertainDescription,
    SubtitleRateCorrection.always => t.settings.subtitleRateCorrectionAlwaysDescription,
  };

  @override
  Widget build(BuildContext context) {
    // Each backend exposes its own text-subtitle placement preference.
    final exoActive = Platform.isAndroid && SettingsService.instance.read(SettingsService.useExoPlayer);
    return SettingsPage(
      title: Text(t.screens.subtitleStyling),
      children: [
        SettingsGroup(
          title: t.videoControls.searchSubtitles,
          children: [
            SettingSwitchTile(
              pref: SettingsService.autoFetchExactSubtitles,
              icon: Symbols.subtitles_rounded,
              title: t.settings.autoFetchSubtitles,
              subtitle: t.settings.autoFetchSubtitlesDescription,
            ),
            // The one knob both subtitle searches read, and until now it had
            // no tile: the value was only ever written by picking a language
            // inside the in-player search sheet, so whatever was searched last
            // silently became the default for the automatic fetch above.
            SettingSelectionTile<String?>(
              pref: SettingsService.subtitleSearchLanguage,
              icon: Symbols.translate_rounded,
              title: t.settings.subtitleSearchLanguage,
              subtitleBuilder: (code) => code == null
                  ? t.settings.subtitleSearchLanguageAutomatic
                  : LanguageCodes.getLanguageName(code) ?? code,
              options: _searchLanguageOptions,
            ),
            // Sits with the fetch rather than the styling: both are about a
            // subtitle being right for this file, not how it looks.
            SettingSelectionTile<SubtitleRateCorrection>(
              pref: SettingsService.subtitleRateCorrection,
              icon: Symbols.av_timer_rounded,
              title: t.settings.subtitleRateCorrection,
              subtitleBuilder: _rateCorrectionDescription,
              options: SubtitleRateCorrection.values
                  .map(
                    (value) => DialogOption(
                      value: value,
                      title: _rateCorrectionLabel(value),
                      subtitle: _rateCorrectionDescription(value),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
        SettingsGroup(
          title: t.subtitlingStyling.text,
          children: [
            SettingSelectionTile<SubAssOverride>(
              pref: SettingsService.subAssOverride,
              icon: Symbols.subtitles_rounded,
              title: t.subtitlingStyling.assOverride,
              subtitleBuilder: _assOverrideLabel,
              options: SubAssOverride.values.map((v) => DialogOption(value: v, title: _assOverrideLabel(v))).toList(),
            ),
            // iOS/tvOS avfoundation VO: screen vs video-resolution basis.
            if (Platform.isIOS)
              SettingSelectionTile<SubtitleRenderResolution>(
                pref: SettingsService.subtitleRenderResolution,
                icon: Symbols.aspect_ratio_rounded,
                title: t.subtitlingStyling.renderResolution,
                subtitleBuilder: _renderResolutionLabel,
                options: const [
                  SubtitleRenderResolution.screen,
                  SubtitleRenderResolution.video,
                ].map((v) => DialogOption(value: v, title: _renderResolutionLabel(v))).toList(),
              ),
            // Android libass overlay: full or a fractional render scale (perf knob for
            // render-bound low-end TVs; heavy/animated signs raster faster at < 1).
            if (Platform.isAndroid)
              SettingSelectionTile<SubtitleRenderResolution>(
                pref: SettingsService.subtitleRenderResolution,
                icon: Symbols.aspect_ratio_rounded,
                title: t.subtitlingStyling.renderResolution,
                subtitleBuilder: _renderResolutionLabel,
                options: const [
                  SubtitleRenderResolution.screen,
                  SubtitleRenderResolution.threeQuarter,
                  SubtitleRenderResolution.half,
                  SubtitleRenderResolution.third,
                  SubtitleRenderResolution.quarter,
                ].map((v) => DialogOption(value: v, title: _renderResolutionLabel(v))).toList(),
              ),
            SettingNumberTile(
              pref: SettingsService.subtitleFontSize,
              icon: Symbols.format_size_rounded,
              title: t.subtitlingStyling.fontSize,
              subtitleBuilder: (v) => '$v',
              labelText: t.subtitlingStyling.fontSize,
              suffixText: '',
            ),
            SettingColorTile(
              pref: SettingsService.subtitleTextColor,
              icon: Symbols.format_color_text_rounded,
              title: t.subtitlingStyling.textColor,
            ),
            SettingNumberTile(
              pref: SettingsService.subtitlePosition,
              icon: Symbols.vertical_align_bottom_rounded,
              title: t.subtitlingStyling.position,
              subtitleBuilder: _formatPosition,
              labelText: t.subtitlingStyling.position,
              suffixText: '%',
            ),
            if (!exoActive)
              SettingSwitchTile(
                pref: SettingsService.subtitleUseMargins,
                icon: Symbols.fit_screen_rounded,
                title: t.subtitlingStyling.useMargins,
                subtitle: t.subtitlingStyling.useMarginsDescription,
              ),
            if (exoActive)
              SettingSwitchTile(
                pref: SettingsService.subtitleAnchorToScreen,
                icon: Symbols.fit_screen_rounded,
                title: t.subtitlingStyling.anchorToScreen,
                subtitle: t.subtitlingStyling.anchorToScreenDescription,
              ),
            SettingSwitchTile(
              pref: SettingsService.subtitleBold,
              icon: Symbols.format_bold_rounded,
              title: t.subtitlingStyling.bold,
            ),
            SettingSwitchTile(
              pref: SettingsService.subtitleItalic,
              icon: Symbols.format_italic_rounded,
              title: t.subtitlingStyling.italic,
            ),
          ],
        ),

        SettingsGroup(
          title: t.subtitlingStyling.border,
          children: [
            SettingNumberTile(
              pref: SettingsService.subtitleBorderSize,
              icon: Symbols.border_style_rounded,
              title: t.subtitlingStyling.borderSize,
              subtitleBuilder: (v) => '$v',
              labelText: t.subtitlingStyling.borderSize,
              suffixText: '',
            ),
            SettingColorTile(
              pref: SettingsService.subtitleBorderColor,
              icon: Symbols.border_color_rounded,
              title: t.subtitlingStyling.borderColor,
            ),
          ],
        ),

        SettingsGroup(
          title: t.subtitlingStyling.background,
          children: [
            SettingNumberTile(
              pref: SettingsService.subtitleBackgroundOpacity,
              icon: Symbols.opacity_rounded,
              title: t.subtitlingStyling.backgroundOpacity,
              subtitleBuilder: (v) => '$v%',
              labelText: t.subtitlingStyling.backgroundOpacity,
              suffixText: '%',
            ),
            SettingColorTile(
              pref: SettingsService.subtitleBackgroundColor,
              icon: Symbols.format_color_fill_rounded,
              title: t.subtitlingStyling.backgroundColor,
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
