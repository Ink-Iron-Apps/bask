/// Whether a download failure was the network being unavailable rather than
/// the server rejecting the request.
///
/// These arrive from the native downloader, whose message text is all we get.
bool isNetworkFailureMessage(String? message) {
  if (message == null || message.isEmpty) return false;
  const needles = [
    'unable to resolve host',
    'no address associated with hostname',
    'failed host lookup',
    'network is unreachable',
    'connection refused',
    'connection reset',
    'software caused connection abort',
    'connection abort',
    'timed out',
  ];
  final normalized = message.toLowerCase();
  return needles.any(normalized.contains);
}
