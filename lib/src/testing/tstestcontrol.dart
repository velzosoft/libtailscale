// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Bindings to upstream's `tstestcontrol` c-shared library: an in-process
/// Tailscale control server plus DERP and STUN on 127.0.0.1.
///
/// Built by the hook when the `build_test_control` user-define (or the
/// same key in `hook/local_config.json`) is set; needs Go.
@DefaultAsset('package:libtailscale/src/testing/tstestcontrol.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

@Native<Int Function(Pointer<Char>, Size)>(symbol: 'run_control')
external int _runControl(Pointer<Char> buf, int len);

@Native<Void Function()>(symbol: 'stop_control')
external void _stopControl();

/// Starts the test control server and returns its URL.
///
/// Throws [ArgumentError] when the native asset is not available (the hook
/// was not asked to build it) and [StateError] when the server fails to start.
String runTestControl() {
  const size = 512;
  final buf = calloc<Char>(size);
  try {
    final rc = _runControl(buf, size);
    if (rc != 0) throw StateError('run_control failed with $rc');
    return buf.cast<Utf8>().toDartString();
  } finally {
    calloc.free(buf);
  }
}

/// Stops the test control server started by [runTestControl].
void stopTestControl() => _stopControl();

/// Whether the test control asset was built into this test run.
bool get testControlAvailable {
  try {
    // Resolving the symbol is enough; do not start anything.
    Native.addressOf<NativeFunction<Void Function()>>(_stopControl);
    return true;
  } on ArgumentError {
    return false;
  }
}
