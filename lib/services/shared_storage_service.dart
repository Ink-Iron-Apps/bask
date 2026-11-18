import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

/// The device's shared storage, and the permission that makes it reachable.
///
/// Exists so an offline library can live somewhere the app's own lifecycle
/// cannot reach. App-private storage is the right default for downloads, but
/// Android deletes it with the app, so a reinstall, a rename or a change of
/// signing key takes the whole library with it. A folder on the shared volume
/// survives all three, and the install that finds one there can adopt it.
///
/// Android has no dialog for this on API 30 and up: `MANAGE_EXTERNAL_STORAGE`
/// is granted on a Settings screen that an app can only open. [requestAccess]
/// therefore reports whether the ask was *started*, never whether it was
/// granted — callers re-read [hasAccess] when they are resumed.
class SharedStorageService {
  SharedStorageService({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.plezy/shared_storage';

  /// The folder a predecessor install leaves its library in, and the one this
  /// app looks in for one.
  ///
  /// Named for this app rather than the one that wrote it: the whole point is
  /// that the folder outlives the install that filled it, and a `plexy` folder
  /// holding Bask's library would be a puzzle on sight.
  static const String folderName = 'Bask';

  final MethodChannel _channel;

  static SharedStorageService? _instance;
  static SharedStorageService get instance => _instance ??= SharedStorageService();

  @visibleForTesting
  static set debugInstance(SharedStorageService? value) => _instance = value;

  /// Replaces the platform gate under test.
  ///
  /// Without it every case skips off Android, and a suite that runs on Linux
  /// and Windows would cover the channel contract nowhere at all.
  @visibleForTesting
  static bool? debugSupportedOverride;

  /// Only Android keeps downloads somewhere the app's lifecycle can delete.
  /// Every other platform this ships on either has a real filesystem or has no
  /// shared volume at all, so there is nothing to adopt.
  static bool get isSupported => debugSupportedOverride ?? (!kIsWeb && Platform.isAndroid);

  Future<T?> _call<T>(String method) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      // An older host that predates the channel. Not an error worth logging on
      // every check — it simply means shared storage is not on offer.
      return null;
    } catch (error, stackTrace) {
      appLogger.w('Shared storage $method failed', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// The shared volume's root, or null when none is mounted.
  Future<String?> root() => _call<String>('getSharedRoot');

  /// Whether the shared volume can be read and written with plain file paths
  /// today.
  Future<bool> hasAccess() async => await _call<bool>('hasAccess') ?? false;

  /// Whether asking is even possible.
  ///
  /// False on Android TV, which generally has no activity for the Settings
  /// screen that grants this. A caller that gets false should stay in
  /// app-private storage rather than offer something that cannot be granted.
  Future<bool> canRequestAccess() async => await _call<bool>('canRequestAccess') ?? false;

  /// Starts the grant. True means the ask began, not that it succeeded.
  Future<bool> requestAccess() async => await _call<bool>('requestAccess') ?? false;

  /// The shared library folder, or null when there is no usable shared volume.
  ///
  /// Does not create it, and does not check the permission: callers that are
  /// only naming the folder should not be made to hold it first.
  Future<Directory?> libraryDirectory() async {
    final base = await root();
    if (base == null || base.isEmpty) return null;
    return Directory('$base/$folderName');
  }
}
