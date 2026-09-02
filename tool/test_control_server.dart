// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Runs upstream's in-process test control server (control plane + DERP +
/// STUN on 127.0.0.1) until interrupted, printing its URL on the first line.
///
/// Needs the `build_test_control` hook option (see `hook/local_config.json`).
/// Point `tsnode --control-url <url> --interactive` at it: the test server
/// approves every node without a key.
library;

import 'dart:async';
import 'dart:io';

import 'package:libtailscale/src/testing/tstestcontrol.dart';

Future<void> main() async {
  if (!testControlAvailable) {
    stderr.writeln(
      'tstestcontrol is not built: add {"build_test_control": true} to '
      'hook/local_config.json and clear .dart_tool/hooks_runner.',
    );
    exitCode = 2;
    return;
  }
  final url = runTestControl();
  stdout.writeln(url);
  await stdout.flush();
  stderr.writeln('test control server running at $url; Ctrl-C to stop');
  // Cancel the watchers afterwards; a live signal subscription would keep
  // the VM alive after stop_control.
  final interrupted = Completer<void>();
  final subscriptions = [
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
      signal.watch().listen((_) {
        if (!interrupted.isCompleted) interrupted.complete();
      }),
  ];
  await interrupted.future;
  for (final s in subscriptions) {
    await s.cancel();
  }
  stopTestControl();
}
