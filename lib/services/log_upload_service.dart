import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../utils/media_server_http_client.dart';

/// Holds the endpoint that diagnostics are posted to.
///
/// Empty by default, and deliberately so. A self-hosted build has no shared
/// relay behind it, and the upstream project's server is not this project's
/// to send other people's logs to. Supply one at build time with
/// `--dart-define=LOG_UPLOAD_ENDPOINT=https://example.invalid/logs`; until
/// then the feature is absent rather than broken.
///
/// A class rather than a bare top-level setter because the unused-code gate
/// scans `lib` alone: a top-level function only the tests call reads as dead
/// code to it, while a static on a class `lib` does use does not.
abstract final class LogUploadEndpoint {
  static const String _configured = String.fromEnvironment('LOG_UPLOAD_ENDPOINT');

  /// The endpoint in force. Empty unless this build defined one.
  static String value = _configured;

  /// Point the uploader somewhere for one test; null restores the build's own.
  @visibleForTesting
  static void setForTesting(String? endpoint) => value = endpoint ?? _configured;
}

/// The endpoint diagnostics are posted to, empty when none is configured.
///
/// Posting to it returns a short, quotable Log ID.
String get logUploadEndpoint => LogUploadEndpoint.value;

/// Whether a log relay is configured.
///
/// Callers check this before offering an upload at all: a control that can
/// only ever fail is worse than no control.
bool get logUploadConfigured => logUploadEndpoint.isNotEmpty;

/// The server's `/logs` accepts 1 MiB. The in-memory buffer intentionally remains
/// larger for local viewing and copying; uploads retain the device header and
/// newest log lines within this transport contract.
const int maxLogUploadBytes = 1 * 1024 * 1024;

/// Trims [logs] from the front so `header + logs` fits [maxBytes], keeping the
/// header intact and never splitting a UTF-8 sequence or a log line.
String constrainLogUploadPayload({required String header, required String logs, int maxBytes = maxLogUploadBytes}) {
  if (maxBytes <= 0) return '';

  final headerBytes = utf8.encode(header);
  if (headerBytes.length >= maxBytes) {
    var end = maxBytes;
    while (end > 0 && end < headerBytes.length && (headerBytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(headerBytes.sublist(0, end));
  }

  final logBytes = utf8.encode(logs);
  final availableLogBytes = maxBytes - headerBytes.length;
  if (logBytes.length <= availableLogBytes) return '$header$logs';

  var start = logBytes.length - availableLogBytes;
  while (start < logBytes.length && (logBytes[start] & 0xC0) == 0x80) {
    start++;
  }
  final nextLine = logBytes.indexOf(0x0A, start);
  if (nextLine >= 0 && nextLine + 1 < logBytes.length) {
    start = nextLine + 1;
  }
  return header + utf8.decode(logBytes.sublist(start));
}

/// Posts [payload] to the log relay and returns the short Log ID.
///
/// Shared by Settings › Logs and by the startup failure screen, which cannot
/// reach Settings because the gate it needs has not completed (#1732).
///
/// [payload] must already be redacted and allowlisted by the caller; this
/// function performs no sanitisation of its own.
Future<String> uploadDiagnosticText(String payload, {MediaServerHttpClient? client}) async {
  if (!logUploadConfigured) {
    throw StateError('No log upload endpoint is configured; build with --dart-define=LOG_UPLOAD_ENDPOINT to enable it');
  }
  final response = await (client ?? httpClient).post(
    logUploadEndpoint,
    body: payload,
    headers: {'Content-Type': 'text/plain'},
  );
  final data = response.data is String ? jsonDecode(response.data as String) : response.data;
  return (data as Map<String, dynamic>)['id'] as String;
}
