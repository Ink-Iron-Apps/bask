import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:window_manager/window_manager.dart' show windowManager;
import '../mixins/disposable_change_notifier_mixin.dart';
import '../services/native_window_service.dart';
import '../services/settings_binding_owner.dart';
import '../services/settings_service.dart' as settings;
import '../theme/mono_theme.dart';
import '../theme/theme_palette.dart';
import '../utils/app_logger.dart';

/// What the app paints: a [settings.ThemeMode] for brightness and a
/// [ThemePalette] for colour. The two are independent — "dark + plum" is a
/// dark theme — and neither is ever gated: every palette is available in
/// every build.
class ThemeProvider extends ChangeNotifier with DisposableChangeNotifierMixin, WidgetsBindingObserver {
  late final SettingsBindingOwner _settingsBinding;
  settings.ThemeMode _themeMode = settings.ThemeMode.system;
  ThemePalette _themePalette = ThemePalette.neutral;
  late Brightness _systemBrightness;
  bool? _windowChromeDark;

  ThemeProvider() {
    _systemBrightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    // Seed synchronously when settings are already loaded (main() initializes
    // them before runApp) so the first frame paints the persisted theme; the
    // async path below lands a microtask too late for the first build.
    final loaded = settings.SettingsService.instanceOrNull;
    if (loaded != null) {
      _themeMode = loaded.read(settings.SettingsService.themeMode);
      _themePalette = loaded.read(settings.SettingsService.themePalette);
    }
    _settingsBinding = SettingsBindingOwner(
      prefs: const [settings.SettingsService.themeMode, settings.SettingsService.themePalette],
      onRefresh: (service) => _syncTheme(
        service.read(settings.SettingsService.themeMode),
        service.read(settings.SettingsService.themePalette),
      ),
    );
    unawaited(_settingsBinding.bind());
    WidgetsBinding.instance.addObserver(this);
    _syncWindowChrome();
  }

  @override
  void didChangePlatformBrightness() {
    _systemBrightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (_themeMode == settings.ThemeMode.system) {
      _syncWindowChrome();
      safeNotifyListeners();
    }
  }

  @override
  void dispose() {
    _settingsBinding.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _syncTheme(settings.ThemeMode mode, ThemePalette palette, {bool forceNotify = false}) {
    final changed = _themeMode != mode || _themePalette != palette;
    _themeMode = mode;
    _themePalette = palette;
    // The Android splash only has mode-named themes; a palette cannot reach it,
    // so the launch screen stays neutral and the palette appears with the
    // first Flutter frame.
    _updateSplashTheme(mode);
    _syncWindowChrome();
    if (changed || forceNotify) safeNotifyListeners();
  }

  settings.ThemeMode get themeMode => _themeMode;
  ThemePalette get themePalette => _themePalette;

  /// Light-slot theme for [palette]. [mode] is taken for symmetry with
  /// [darkThemeFor] and because a mode that is never light still has to hand
  /// Material something for the slot.
  ///
  /// Static so the pre-provider startup frame can resolve the same theme this
  /// provider will settle on, instead of guessing from platform brightness
  /// and flashing when the two disagree (#1833).
  static ThemeData lightThemeFor(settings.ThemeMode mode, [ThemePalette palette = ThemePalette.neutral]) =>
      monoTheme(palette.monoFor(dark: false, oled: false));

  /// Dark-slot theme for [palette], pure black under [settings.ThemeMode.oled].
  static ThemeData darkThemeFor(settings.ThemeMode mode, [ThemePalette palette = ThemePalette.neutral]) =>
      monoTheme(palette.monoFor(dark: true, oled: mode == settings.ThemeMode.oled));

  /// Material equivalent of the app's own [settings.ThemeMode].
  static ThemeMode materialThemeModeFor(settings.ThemeMode mode) => switch (mode) {
    settings.ThemeMode.light => ThemeMode.light,
    settings.ThemeMode.dark => ThemeMode.dark,
    settings.ThemeMode.oled => ThemeMode.dark,
    settings.ThemeMode.system => ThemeMode.system,
  };

  ThemeData get lightTheme => lightThemeFor(_themeMode, _themePalette);
  ThemeData get darkTheme => darkThemeFor(_themeMode, _themePalette);

  ThemeMode get materialThemeMode => materialThemeModeFor(_themeMode);

  /// Whether [mode] paints dark when the platform reports [platformBrightness].
  ///
  /// Static so the startup frame, which runs before this provider exists, can
  /// theme the window frame with the same answer.
  static bool isDarkFor(settings.ThemeMode mode, Brightness platformBrightness) => switch (mode) {
    settings.ThemeMode.light => false,
    settings.ThemeMode.dark => true,
    settings.ThemeMode.oled => true,
    settings.ThemeMode.system => platformBrightness == Brightness.dark,
  };

  bool get isDarkMode => isDarkFor(_themeMode, _systemBrightness);

  /// Themes the native window frame, which Flutter does not paint, to match the app.
  ///
  /// Neither desktop frame follows the app on its own: the GTK3 title bar on Linux keeps the GTK theme's light
  /// variant even under GNOME's dark style, and the Windows caption follows the OS app theme (#2622). macOS needs
  /// nothing: its title bar is transparent over Flutter content. Best-effort, because a frame left in the platform's
  /// own theme is the correct fallback.
  ///
  /// Static so startup can theme the frame as soon as settings load, before this provider exists.
  static void applyWindowChromeBrightness(bool dark) {
    final Future<void> applied;
    if (Platform.isLinux) {
      applied = windowManager.setBrightness(dark ? Brightness.dark : Brightness.light);
    } else if (Platform.isWindows) {
      applied = NativeWindowService.setDarkMode(dark);
    } else {
      return;
    }
    unawaited(
      applied.catchError((Object error, StackTrace stackTrace) {
        appLogger.d('Window frame theme not applied', error: error, stackTrace: stackTrace);
      }),
    );
  }

  void _syncWindowChrome() {
    if (isDisposed) return;
    final dark = isDarkMode;
    if (_windowChromeDark == dark) return;
    _windowChromeDark = dark;
    applyWindowChromeBrightness(dark);
  }

  static const _themeChannel = MethodChannel('com.plezy/theme');

  @visibleForTesting
  Future<void> setThemeMode(settings.ThemeMode mode) async {
    final service = _settingsBinding.settings ?? await settings.SettingsService.getInstance();
    if (service.read(settings.SettingsService.themeMode) == mode) return;
    await service.write(settings.SettingsService.themeMode, mode);
    if (_settingsBinding.settings == null) _syncTheme(mode, _themePalette);
  }

  Future<void> reload() async {
    await _settingsBinding.bind();
    final service = _settingsBinding.settings;
    if (service != null) {
      _syncTheme(
        service.read(settings.SettingsService.themeMode),
        service.read(settings.SettingsService.themePalette),
        forceNotify: true,
      );
    }
  }

  void _updateSplashTheme(settings.ThemeMode mode) {
    if (!Platform.isAndroid) return;
    _themeChannel.invokeMethod('setSplashTheme', {'mode': nativeSplashMode(mode)});
  }

  /// Launch-screen mode the Android side understands. It only knows the
  /// built-in launch colours (`ThemeHelper.themeColor` and the `SplashTheme_*`
  /// styles), so a palette never reaches it: the launch screen is the mode's
  /// own, and the first Flutter frame paints the palette.
  @visibleForTesting
  static String nativeSplashMode(settings.ThemeMode mode) => switch (mode) {
    settings.ThemeMode.system => 'system',
    settings.ThemeMode.light => 'light',
    settings.ThemeMode.dark => 'dark',
    settings.ThemeMode.oled => 'oled',
  };

  IconData get themeModeIcon => switch (_themeMode) {
    settings.ThemeMode.light => Symbols.light_mode_rounded,
    settings.ThemeMode.dark => Symbols.dark_mode_rounded,
    settings.ThemeMode.oled => Symbols.contrast_rounded,
    settings.ThemeMode.system => Symbols.brightness_auto_rounded,
  };
}
