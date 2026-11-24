import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// Optional read token for the releases API, supplied at build time.
///
/// Normally empty, and meant to stay that way: this repository is public, so
/// its releases and their assets are readable without credentials. A token is
/// only useful if the releases ever move somewhere private, and it must not be
/// supplied for a build that is published — a `--dart-define` is compiled into
/// the APK, and an APK from a public repository is a public artifact, so the
/// token would ship to anyone who downloads it.
const _updateReadToken = String.fromEnvironment('UPDATE_READ_TOKEN');

/// Releases are read straight from the source repository.
///
/// CI passes the repository it is building from, so a transfer or rename
/// corrects this by itself; the default only covers a local build.
///
/// It has to be right rather than merely redirect-able: GitHub answers a moved
/// repository with a 301, and [AppUpdateService._get] deliberately drops the
/// Authorization header across a redirect, because asset storage rejects a
/// request that carries both its own credentials and ours.
const _releasesApiBase = String.fromEnvironment(
  'UPDATE_RELEASES_REPO',
  defaultValue: 'https://api.github.com/repos/Ink-Iron-Apps/bask-media-player',
);

/// Whether [latest] is a higher version than [current].
///
/// Compares numerically per component, so 2.10.0 beats 2.9.0 — a string
/// compare gets that backwards and would strand the app one release behind.
/// A version that cannot be parsed yields false: never offer an update that
/// cannot be reasoned about.
bool isNewerVersion({required String latest, required String current}) {
  List<int>? parse(String raw) {
    final trimmed = raw.trim().replaceFirst(RegExp('^v'), '');
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split('.');
    final numbers = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part.split('-').first);
      if (value == null) return null;
      numbers.add(value);
    }
    return numbers.isEmpty ? null : numbers;
  }

  final latestParts = parse(latest);
  final currentParts = parse(current);
  if (latestParts == null || currentParts == null) return false;

  for (var i = 0; i < (latestParts.length > currentParts.length ? latestParts.length : currentParts.length); i++) {
    final l = i < latestParts.length ? latestParts[i] : 0;
    final c = i < currentParts.length ? currentParts[i] : 0;
    if (l != c) return l > c;
  }
  return false;
}

/// The release asset to install on a device supporting [abis], in preference order.
///
/// Falls back to an APK with no ABI in its name — a universal build — so a
/// device on an architecture we do not publish per-ABI still updates.
///
/// The ABI has to be a whole trailing name component: 'x86_64'.contains('x86')
/// is true, so a substring match would hand an x86-only device — an emulator,
/// usually — a 64-bit APK it cannot install.
Map<String, dynamic>? selectApkAsset(List<Map<String, dynamic>> assets, {required List<String> abis}) {
  final apks = assets.where((a) => (a['name'] as String? ?? '').endsWith('.apk')).toList();
  if (apks.isEmpty) return null;

  bool carries(String name, String abi) => name.endsWith('-$abi.apk');

  for (final abi in abis) {
    for (final apk in apks) {
      if (carries(apk['name'] as String, abi)) return apk;
    }
  }

  const knownAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];
  for (final apk in apks) {
    final name = apk['name'] as String;
    if (!knownAbis.any((abi) => carries(name, abi))) return apk;
  }
  return null;
}

/// The ABI order assumed when the device cannot tell us its own.
///
/// 32-bit first, deliberately. This list is only reached when the platform
/// channel fails, so it has to degrade safely rather than optimally: a 64-bit
/// device runs the armeabi-v7a build, but a 32-bit device — an older Android TV,
/// typically — cannot install the arm64-v8a one, and the failure only surfaces
/// after the whole APK has been downloaded.
const fallbackDeviceAbis = ['armeabi-v7a', 'arm64-v8a'];

/// An update available on the release mirror.
@immutable
class AvailableUpdate {
  const AvailableUpdate({required this.version, required this.assetUrl, required this.assetName, this.notes = ''});

  final String version;

  /// The asset's API URL, not `browser_download_url`: only the former can be
  /// fetched with a token on a private repository.
  final String assetUrl;
  final String assetName;

  /// The release body, as written by the release workflow. Empty when the
  /// release carried none — worth showing when it is there, since a sideloaded
  /// build has no store listing to explain what changed.
  final String notes;
}

/// Checks the private release mirror, downloads the matching APK, and hands it
/// to Android's installer.
class AppUpdateService {
  AppUpdateService({HttpClient? httpClient}) : _httpClient = httpClient ?? HttpClient();

  static const _channel = MethodChannel('com.plezy/apk_install');

  final HttpClient _httpClient;

  /// Android sideloads update themselves. Static so the Settings screen can
  /// decide whether to show the section without building a service first.
  static bool get isSupportedPlatform => !kIsWeb && Platform.isAndroid;

  bool get isSupported => isSupportedPlatform;
  bool get hasToken => _updateReadToken.isNotEmpty;

  /// Latest release if it is newer than the running build, else null.
  ///
  /// Throws [AppUpdateException] with a specific message on a rejected or
  /// unreachable repository, so a failed check cannot masquerade as "up to
  /// date". No token is required: a public repository answers both the release
  /// read and the asset download unauthenticated.
  Future<AvailableUpdate?> checkForUpdate() async {
    if (!isSupported) return null;

    final response = await _get(Uri.parse('$_releasesApiBase/releases/latest'), accept: 'application/vnd.github+json');
    if (response.statusCode != 200) {
      throw AppUpdateException(switch (response.statusCode) {
        401 || 403 =>
          'Update check rejected (HTTP ${response.statusCode}) — too many checks from this network, or the releases '
              'are no longer public.',
        404 => 'No releases found (HTTP 404) — the update repository may have moved.',
        _ => 'Update check failed (HTTP ${response.statusCode}).',
      });
    }

    final body = json.decode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>;
    final tag = body['tag_name'] as String? ?? '';
    final current = (await PackageInfo.fromPlatform()).version;
    if (!isNewerVersion(latest: tag, current: current)) return null;

    final assets = (body['assets'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    final asset = selectApkAsset(assets, abis: await _deviceAbis());
    if (asset == null) {
      throw AppUpdateException('$tag is available but carries no APK this device can install.');
    }
    return AvailableUpdate(
      version: tag.replaceFirst(RegExp('^v'), ''),
      assetUrl: asset['url'] as String,
      assetName: asset['name'] as String,
      notes: (body['body'] as String? ?? '').trim(),
    );
  }

  /// Downloads [update] and starts the system installer.
  ///
  /// [onProgress] receives 0..1 while downloading.
  Future<void> downloadAndInstall(AvailableUpdate update, {void Function(double)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/bask-update.apk');
    if (file.existsSync()) await file.delete();

    final response = await _get(Uri.parse(update.assetUrl), accept: 'application/octet-stream');
    if (response.statusCode != 200) {
      throw AppUpdateException('Download failed (HTTP ${response.statusCode}).');
    }

    final total = response.contentLength;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.close();
    }

    if (!await canRequestInstall()) {
      await openInstallPermissionSettings();
      throw const AppUpdateException('Allow Bask to install unknown apps, then run the update again.');
    }
    await _channel.invokeMethod<bool>('installApk', {'path': file.path});
  }

  Future<bool> canRequestInstall() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('canRequestInstall') ?? false;
  }

  Future<void> openInstallPermissionSettings() async {
    if (!isSupported) return;
    await _channel.invokeMethod<bool>('openInstallPermissionSettings');
  }

  /// Issues the request, following redirects by hand.
  ///
  /// An asset answers with a 302 to storage that carries its own credentials
  /// and rejects a request that also sends ours, so the Authorization header
  /// is dropped on the hop. The header is only sent in the first place when a
  /// token was built in, which a public repository does not need.
  Future<HttpClientResponse> _get(Uri uri, {required String accept}) async {
    final request = await _httpClient.getUrl(uri);
    request.followRedirects = false;
    if (hasToken) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_updateReadToken');
    request.headers.set(HttpHeaders.acceptHeader, accept);
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    request.headers.set(HttpHeaders.userAgentHeader, 'Bask');
    final response = await request.close();

    if (response.isRedirect) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null || location.isEmpty) {
        throw const AppUpdateException('Asset redirect carried no location.');
      }
      final redirected = await _httpClient.getUrl(uri.resolve(location));
      redirected.followRedirects = true;
      redirected.headers.set(HttpHeaders.userAgentHeader, 'Bask');
      return redirected.close();
    }
    return response;
  }

  Future<List<String>> _deviceAbis() async {
    try {
      final abis = await const MethodChannel('com.plezy/device').invokeListMethod<String>('getSupportedAbis');
      if (abis != null && abis.isNotEmpty) return abis;
    } catch (e) {
      appLogger.d('Could not read supported ABIs: $e');
    }
    return fallbackDeviceAbis;
  }
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}
