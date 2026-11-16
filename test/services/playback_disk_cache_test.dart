import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bask/services/playback_disk_cache.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('plezy-playback-cache');
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a file the test only just released.
    }
  });

  File writeFile(String name, {required Duration age, int bytes = 1024}) {
    final file = File('${directory.path}/$name')..writeAsBytesSync(List.filled(bytes, 0));
    file.setLastModifiedSync(DateTime.now().subtract(age));
    return file;
  }

  test('removes a cache file older than the retention window', () async {
    final stale = writeFile('stale.tmp', age: const Duration(hours: 3));

    final reclaimed = await PlaybackDiskCache.prune(directory);

    expect(stale.existsSync(), isFalse);
    expect(reclaimed, 1024);
  });

  test('keeps a file from a session that could still be paused', () async {
    // Two hours is the line: a paused film must not have its buffer swept out
    // from under it.
    final fresh = writeFile('fresh.tmp', age: const Duration(minutes: 90));

    await PlaybackDiskCache.prune(directory);

    expect(fresh.existsSync(), isTrue);
  });

  test('sweeps only what has expired', () async {
    final stale = writeFile('stale.tmp', age: const Duration(days: 1), bytes: 2048);
    final fresh = writeFile('fresh.tmp', age: const Duration(minutes: 5));

    final reclaimed = await PlaybackDiskCache.prune(directory);

    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(reclaimed, 2048);
  });

  test('honours an explicit clock so expiry is not wall-clock dependent', () async {
    final file = writeFile('file.tmp', age: const Duration(minutes: 30));

    await PlaybackDiskCache.prune(directory, now: DateTime.now().add(const Duration(hours: 4)));

    expect(file.existsSync(), isFalse);
  });

  test('a missing directory is not an error', () async {
    final absent = Directory('${directory.path}/gone');

    expect(await PlaybackDiskCache.prune(absent), 0);
  });

  test('leaves subdirectories alone', () async {
    final nested = Directory('${directory.path}/nested')..createSync();

    await PlaybackDiskCache.prune(directory, now: DateTime.now().add(const Duration(days: 7)));

    expect(nested.existsSync(), isTrue);
  });
}
