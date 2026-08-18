import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// Read-only token for the release mirror, supplied at build time.
///
/// Empty in local builds, which surfaces as "updates must be installed
/// manually" rather than as "no updates available" — a build that silently
/// never updates is worse than one that says why.
const _updateReadToken = String.fromEnvironment('UPDATE_READ_TOKEN');

/// Releases are read straight from the private source repository.
///
/// A separate artifacts-only mirror would keep the embedded token away from
/// source if a build were shared, which is worth doing for a distributed app.
/// This one is built for a single device and never handed out, so the mirror
/// would add a repository, a second token and a CI step to guard against
/// something that cannot happen here.
const _releasesApiBase = String.fromEnvironment(
  'UPDATE_RELEASES_REPO',
  defaultValue: 'https://api.github.com/repos/LightWraith8268/plexy',
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

/// An update available on the release mirror.
@immutable
class AvailableUpdate {
  const AvailableUpdate({required this.version, required this.assetUrl, required this.assetName});

  final String version;

  /// The asset's API URL, not `browser_download_url`: only the former can be
  /// fetched with a token on a private repository.
  final String assetUrl;
  final String assetName;
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
  /// missing mirror, so an expired token cannot masquerade as "up to date".
  Future<AvailableUpdate?> checkForUpdate() async {
    if (!isSupported) return null;
    if (!hasToken) {
      throw const AppUpdateException('This build has no update token — updates must be installed manually.');
    }

    final response = await _get(Uri.parse('$_releasesApiBase/releases/latest'), accept: 'application/vnd.github+json');
    if (response.statusCode != 200) {
      throw AppUpdateException(switch (response.statusCode) {
        401 || 403 => 'Update check rejected (HTTP ${response.statusCode}) — the release token is expired or revoked.',
        404 => 'Release mirror not found (HTTP 404) — the token may not cover it.',
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
    );
  }

  /// Downloads [update] and starts the system installer.
  ///
  /// [onProgress] receives 0..1 while downloading.
  Future<void> downloadAndInstall(AvailableUpdate update, {void Function(double)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/plexy-update.apk');
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
      throw const AppUpdateException('Allow Plexy to install unknown apps, then run the update again.');
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

  /// Issues a request carrying the token, following redirects by hand.
  ///
  /// A private asset answers with a 302 to pre-signed storage that carries its
  /// own credentials and rejects a request that also sends ours, so the
  /// Authorization header is dropped on the hop.
  Future<HttpClientResponse> _get(Uri uri, {required String accept}) async {
    final request = await _httpClient.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_updateReadToken');
    request.headers.set(HttpHeaders.acceptHeader, accept);
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    request.headers.set(HttpHeaders.userAgentHeader, 'Plexy');
    final response = await request.close();

    if (response.isRedirect) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null || location.isEmpty) {
        throw const AppUpdateException('Asset redirect carried no location.');
      }
      final redirected = await _httpClient.getUrl(uri.resolve(location));
      redirected.followRedirects = true;
      redirected.headers.set(HttpHeaders.userAgentHeader, 'Plexy');
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
    return const ['arm64-v8a', 'armeabi-v7a'];
  }
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}
