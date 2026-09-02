// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// A headless Tailscale / Headscale node for Dart and Flutter, embedded
/// through `dart:ffi` bindings to the official libtailscale C library.
///
/// Configure a [TailscaleNode] with a control URL and one
/// [TailscaleCredential], call [TailscaleNode.start] and
/// [TailscaleNode.waitUntilRunning], then operate over the tailnet with
/// [TailscaleNode.connect], [TailscaleNode.httpClient] and
/// [TailscaleNode.listen].
library;

export 'src/api/addresses.dart';
export 'src/api/config.dart';
export 'src/api/exceptions.dart';
export 'src/api/node.dart';
export 'src/api/sockets.dart';
export 'src/api/state.dart';
export 'src/api/status.dart';
export 'src/ffi/tailscale_api.dart' show LoopbackInfo, NativeTailscale;
export 'src/runtime/local_api.dart';
export 'src/runtime/native_worker.dart';
export 'src/runtime/oauth_exchange.dart';
export 'src/runtime/socks5.dart' show Socks5Client, Socks5Socket, Socks5Reply;
