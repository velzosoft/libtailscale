// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:isolate';

/// Runs blocking native calls somewhere they cannot freeze the caller.
///
/// Go blocks the calling OS thread for `tailscale_start`, `tailscale_dial`,
/// `tailscale_status_json` and friends. A blocked helper isolate is harmless;
/// a blocked main isolate freezes a Flutter UI. The closure passed to [run]
/// must only capture values that can be sent to another isolate (ints,
/// strings, and stateless objects such as `FfiTailscale`).
abstract interface class NativeWorker {
  /// Runs [computation] and completes with its result or error.
  Future<R> run<R>(R Function() computation, {String? debugName});
}

/// A [NativeWorker] that runs every computation on a fresh short-lived
/// isolate via [Isolate.run].
final class IsolateNativeWorker implements NativeWorker {
  /// Creates the worker.
  const IsolateNativeWorker();

  @override
  Future<R> run<R>(R Function() computation, {String? debugName}) =>
      Isolate.run(computation, debugName: debugName ?? 'libtailscale-worker');
}

/// A [NativeWorker] that runs computations on the calling isolate.
///
/// Useful for tests with fakes and for command-line tools that do not mind
/// blocking. Never use it in a Flutter UI isolate.
final class InlineNativeWorker implements NativeWorker {
  /// Creates the worker.
  const InlineNativeWorker();

  @override
  Future<R> run<R>(R Function() computation, {String? debugName}) =>
      Future<R>.sync(computation);
}
