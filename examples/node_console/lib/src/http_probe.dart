// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libtailscale/libtailscale.dart';

/// What came back from an HTTP request made through the node.
final class FetchResult {
  /// Creates a result.
  const FetchResult({
    required this.url,
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.bodyBytes,
    required this.elapsed,
    required this.preview,
  });

  /// The requested URL.
  final Uri url;

  /// HTTP status code.
  final int statusCode;

  /// HTTP reason phrase.
  final String reasonPhrase;

  /// Response headers, multi-valued ones joined with `, `.
  final Map<String, String> headers;

  /// Total body size.
  final int bodyBytes;

  /// Wall-clock time for the whole exchange.
  final Duration elapsed;

  /// The first bytes of the body, decoded leniently as UTF-8.
  final String preview;
}

/// Maximum number of body bytes kept in [FetchResult.preview].
const previewLimit = 2048;

/// GETs [url] over the tailnet with `node.httpClient()`.
///
/// Works for MagicDNS names and tailnet IPs alike; the client is closed
/// afterwards. Throws the usual `dart:io` exceptions on failure.
Future<FetchResult> fetchOverTailnet(
  TailscaleNode node,
  Uri url, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = node.httpClient(connectionTimeout: timeout);
  final stopwatch = Stopwatch()..start();
  try {
    final request = await client.getUrl(url).timeout(timeout);
    final response = await request.close().timeout(timeout);
    var bytes = 0;
    final preview = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      bytes += chunk.length;
      final room = previewLimit - preview.length;
      if (room > 0) {
        preview.add(
          chunk.length <= room
              ? chunk
              : Uint8List.sublistView(Uint8List.fromList(chunk), 0, room),
        );
      }
    }
    final headers = <String, String>{};
    response.headers.forEach(
      (String name, List<String> values) => headers[name] = values.join(', '),
    );
    return FetchResult(
      url: url,
      statusCode: response.statusCode,
      reasonPhrase: response.reasonPhrase,
      headers: headers,
      bodyBytes: bytes,
      elapsed: stopwatch.elapsed,
      preview: utf8.decode(preview.takeBytes(), allowMalformed: true),
    );
  } finally {
    client.close(force: true);
  }
}
