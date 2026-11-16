// ignore_for_file: prefer_initializing_formals - Dart forbids a named
// parameter that starts with an underscore, so a private field behind a
// public named parameter has to be assigned in the initializer list.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../utils/app_logger.dart';
import 'settings_export_service.dart';
import 'settings_service.dart';

/// Keeps a recent settings backup in the app's own documents directory, so a
/// reinstall, a wiped profile or a rename has something to restore from
/// without anyone having remembered to export.
///
/// Two triggers, because either alone leaves a hole. A change-driven write
/// catches the settings someone just spent an evening tuning; a staleness
/// check at startup catches the install whose settings were perfect a year
/// ago and never touched since, where a change-driven backup would never
/// fire at all.
///
/// Settings only. [SettingsExportService.writeAutomaticBackup] carries no
/// credentials and the service never asks for a passphrase: a backup written
/// unattended cannot be protected by one, and writing an unprotected
/// credential file on a timer is the opposite of a safety net.
class SettingsAutoExportService {
  SettingsAutoExportService({
    required SettingsService settings,
    @visibleForTesting Duration debounce = const Duration(seconds: 60),
    @visibleForTesting Duration staleAfter = const Duration(hours: 24),
    @visibleForTesting Future<String?> Function()? writeBackup,
    @visibleForTesting Future<DateTime?> Function()? lastBackupAt,
  }) : _settings = settings,
       _debounce = debounce,
       _staleAfter = staleAfter,
       _writeBackup = writeBackup ?? SettingsExportService.writeAutomaticBackup,
       _lastBackupAt = lastBackupAt ?? _newestBackupTime;

  final SettingsService _settings;
  final Duration _debounce;
  final Duration _staleAfter;
  final Future<String?> Function() _writeBackup;
  final Future<DateTime?> Function() _lastBackupAt;

  Timer? _pending;
  bool _started = false;
  bool _writing = false;

  /// Exposed so a test can await the write a change scheduled.
  @visibleForTesting
  Future<void> get settled => _settled?.future ?? Future<void>.value();
  Completer<void>? _settled;

  static Future<DateTime?> _newestBackupTime() async => (await SettingsExportService.newestAutomaticBackup())?.modified;

  /// Begins watching, and writes immediately when the newest backup has aged
  /// past [staleAfter].
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _settings.storeRevision.addListener(_onStoreChanged);
    await _writeIfStale();
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    _settings.storeRevision.removeListener(_onStoreChanged);
    _pending?.cancel();
    _pending = null;
  }

  /// Whether the viewer has left automatic backups on.
  bool get _enabled => _settings.read(SettingsService.autoExportSettings);

  void _onStoreChanged() {
    if (!_enabled) return;
    // Settings arrive in bursts — a screen of toggles, a dialog applying
    // several at once — so the write waits for the burst to end rather than
    // rewriting the file once per switch.
    _pending?.cancel();
    _settled ??= Completer<void>();
    _pending = Timer(_debounce, () {
      _pending = null;
      unawaited(_write());
    });
  }

  Future<void> _writeIfStale() async {
    if (!_enabled) return;
    final last = await _lastBackupAt();
    if (last != null && DateTime.now().difference(last) < _staleAfter) return;
    await _write();
  }

  Future<void> _write() async {
    if (!_enabled || _writing) return;
    _writing = true;
    try {
      await _writeBackup();
    } catch (error, stackTrace) {
      // A backup is a convenience; failing one must never surface to the
      // viewer or interrupt what they were doing.
      appLogger.w('Automatic settings backup failed', error: error, stackTrace: stackTrace);
    } finally {
      _writing = false;
      _settled?.complete();
      _settled = null;
    }
  }

  /// Writes now, regardless of staleness, when backups are on.
  @visibleForTesting
  Future<void> writeNow() => _write();
}
