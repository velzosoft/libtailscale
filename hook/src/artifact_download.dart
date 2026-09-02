// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:crypto/crypto.dart';

/// SHA-256 of [file] as lowercase hex.
Future<String> sha256OfFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// Downloads and verifies prebuilt native libraries.
final class ArtifactDownloader {
  /// Creates a downloader that caches into [cacheDir] and logs via [log].
  ArtifactDownloader({
    required this.cacheDir,
    required this.log,
    HttpClient Function()? createHttpClient,
  }) : _createHttpClient = createHttpClient ?? HttpClient.new;

  /// Directory for verified downloads (typically `outputDirectoryShared`).
  final Uri cacheDir;

  /// Progress sink.
  final void Function(String message) log;

  final HttpClient Function() _createHttpClient;

  /// Returns a local file with the content of [url] whose SHA-256 is
  /// [expectedSha256], downloading it unless a verified copy is cached.
  Future<File> fetch({
    required Uri url,
    required String expectedSha256,
    required String fileName,
  }) async {
    final dir = Directory.fromUri(cacheDir);
    await dir.create(recursive: true);
    final target = File.fromUri(
      cacheDir.resolve('${expectedSha256.substring(0, 16)}-$fileName'),
    );
    if (target.existsSync() && await sha256OfFile(target) == expectedSha256) {
      log('using cached ${target.path}');
      return target;
    }
    final temp = File('${target.path}.part');
    log('downloading $url');
    final client = _createHttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'GET $url returned HTTP ${response.statusCode}',
          uri: url,
        );
      }
      final sink = temp.openWrite();
      try {
        await response.pipe(sink);
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
    final actual = await sha256OfFile(temp);
    if (actual != expectedSha256) {
      await temp.delete();
      throw StateError(
        'checksum mismatch for $url: expected $expectedSha256, got $actual',
      );
    }
    await temp.rename(target.path);
    return target;
  }
}
