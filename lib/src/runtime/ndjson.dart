// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';

/// Decodes a newline-delimited JSON byte stream into JSON objects.
///
/// Blank lines are skipped. Lines that are not JSON objects are reported as
/// [FormatException]s on the output stream rather than terminating it, so a
/// single odd line cannot kill an IPN bus subscription.
///
/// Implemented with transformers rather than an `async*` generator on
/// purpose: cancelling a generator that is suspended in `await for` only takes
/// effect at its next `yield`, which never comes on an idle long-poll.
final class NdjsonDecoder
    extends StreamTransformerBase<List<int>, Map<String, Object?>> {
  /// Creates the decoder.
  const NdjsonDecoder();

  @override
  Stream<Map<String, Object?>> bind(Stream<List<int>> stream) => stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .transform(
        StreamTransformer<String, Map<String, Object?>>.fromHandlers(
          handleData: _decodeLine,
        ),
      );

  static void _decodeLine(String line, EventSink<Map<String, Object?>> sink) {
    if (line.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (e) {
      sink.addError(e);
      return;
    }
    if (decoded is Map<String, Object?>) {
      sink.add(decoded);
    } else {
      sink.addError(FormatException('expected a JSON object per line', line));
    }
  }
}
