// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';

import 'package:libtailscale/src/runtime/ndjson.dart';
import 'package:test/test.dart';

void main() {
  Stream<List<int>> chunks(List<String> parts) =>
      Stream.fromIterable(parts.map(utf8.encode));

  test(
    'decodes objects across chunk boundaries and skips blank lines',
    () async {
      final out = await chunks([
        '{"a":1}\n\n{"b"',
        ':2}\n{"c":3}',
      ]).transform(const NdjsonDecoder()).toList();
      expect(out, [
        {'a': 1},
        {'b': 2},
        {'c': 3},
      ]);
    },
  );

  test('reports bad lines as errors without ending the stream', () async {
    final events = <Object>[];
    final done = Completer<void>();
    chunks(['{"a":1}\nnot json\n[1,2]\n{"z":9}\n'])
        .transform(const NdjsonDecoder())
        .listen(events.add, onError: events.add, onDone: done.complete);
    await done.future;
    expect(events, hasLength(4));
    expect(events[0], {'a': 1});
    expect(events[1], isA<FormatException>());
    expect(events[2], isA<FormatException>());
    expect(events[3], {'z': 9});
  });
}
