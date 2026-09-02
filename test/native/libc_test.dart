// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['native'])
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:libtailscale/src/ffi/libc.dart';
import 'package:test/test.dart';

void main() {
  test('pipe round trip', () {
    final (r, w) = Libc.pipe();
    final buf = calloc<Uint8>(16);
    try {
      buf.asTypedList(16).setAll(0, [1, 2, 3]);
      expect(Libc.write(w, buf, 3), 3);
      final out = calloc<Uint8>(16);
      try {
        expect(Libc.read(r, out, 16), 3);
        expect(out.asTypedList(3), [1, 2, 3]);
      } finally {
        calloc.free(out);
      }
    } finally {
      calloc.free(buf);
      Libc.close(r);
      Libc.close(w);
    }
  });

  test('non-blocking read reports EAGAIN via errno', () {
    final (a, b) = Libc.socketpair();
    Libc.setNonBlocking(a);
    final buf = calloc<Uint8>(4);
    try {
      expect(Libc.read(a, buf, 4), -1);
      expect(Libc.errno, LibcConstants.eagain);
    } finally {
      calloc.free(buf);
      Libc.close(a);
      Libc.close(b);
    }
  });

  test('shutdown(SHUT_WR) makes the peer see EOF', () {
    final (a, b) = Libc.socketpair();
    final buf = calloc<Uint8>(4);
    try {
      expect(Libc.shutdown(a, LibcConstants.shutWr), 0);
      expect(Libc.read(b, buf, 4), 0);
    } finally {
      calloc.free(buf);
      Libc.close(a);
      Libc.close(b);
    }
  });

  test('strerror and LibcException', () {
    expect(
      Libc.strerror(LibcConstants.ebadf).toLowerCase(),
      contains('bad file'),
    );
    expect(
      LibcException('pipe', LibcConstants.ebadf).toString(),
      contains('pipe'),
    );
    expect(Libc.close(-1), -1);
    expect(Libc.errno, LibcConstants.ebadf);
  });

  test('getenv and setenv round-trip through the C environment', () {
    const name = 'LIBTAILSCALE_TEST_ENV';
    expect(Libc.getenv(name), isNull);
    Libc.setenv(name, 'one');
    expect(Libc.getenv(name), 'one');
    Libc.setenv(name, 'two', overwrite: false);
    expect(Libc.getenv(name), 'one', reason: 'overwrite: false keeps it');
    Libc.setenv(name, 'two');
    expect(Libc.getenv(name), 'two');
  });
}
