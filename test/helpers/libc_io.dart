// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:libtailscale/src/ffi/libc.dart';

/// `write(2)` of `bytes[offset..]` through a temporary native buffer.
int libcWrite(int fd, Uint8List bytes, int offset) {
  final len = bytes.length - offset;
  final buf = malloc<Uint8>(len);
  try {
    buf.asTypedList(len).setAll(0, bytes.sublist(offset));
    return Libc.write(fd, buf, len);
  } finally {
    malloc.free(buf);
  }
}

/// `read(2)` of up to [max] bytes; throws on error, empty list on EOF.
Uint8List libcRead(int fd, int max) {
  final buf = malloc<Uint8>(max);
  try {
    final n = Libc.read(fd, buf, max);
    if (n < 0) throw LibcException('read', Libc.errno);
    return Uint8List.fromList(buf.asTypedList(n));
  } finally {
    malloc.free(buf);
  }
}
