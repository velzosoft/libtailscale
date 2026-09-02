// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'state.dart';

/// Base class for every error raised by this package.
abstract class TailscaleException implements Exception {
  /// Creates an exception carrying [message].
  const TailscaleException(this.message);

  /// Human-readable description.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A `tailscale_*` C call failed.
///
/// [code] is `-1` when libtailscale reported an error through
/// `tailscale_errmsg` (the text is in [message]) or a positive `errno` value
/// such as `EBADF` or `ERANGE`.
final class TailscaleNativeException extends TailscaleException {
  /// Creates an exception for the C [function] returning [code].
  const TailscaleNativeException(this.function, this.code, String message)
    : super(message);

  /// The C function that failed, e.g. `tailscale_start`.
  final String function;

  /// `-1` or an `errno` value.
  final int code;

  @override
  String toString() =>
      'TailscaleNativeException: $function: $message (code $code)';
}

/// The node (or socket) was used after it was closed.
final class TailscaleClosedException extends TailscaleException {
  /// Creates the exception with an optional custom [message].
  const TailscaleClosedException([super.message = 'the node is closed']);
}

/// The node reached a state that requires authentication the library cannot
/// perform on its own (`NeedsLogin` or `NeedsMachineAuth`).
///
/// With [TailscaleCredential.interactive] the login URL is in [authUrl].
final class TailscaleAuthRequiredException extends TailscaleException {
  /// Creates the exception for [state] with the optional [authUrl].
  const TailscaleAuthRequiredException(this.state, {this.authUrl})
    : super('authentication required (backend state: $state)');

  /// The backend state that triggered the failure.
  final BackendState state;

  /// Login URL published by the control server, if any.
  final String? authUrl;
}

/// Waiting for the node to become usable exceeded the timeout.
///
/// [lastState] and [health] carry the last observed backend state and health
/// messages so that a wrong control URL or a rejected key can be diagnosed
/// from logs alone.
final class TailscaleTimeoutException extends TailscaleException {
  /// Creates the exception.
  TailscaleTimeoutException(
    this.timeout, {
    required this.lastState,
    this.health = const [],
  }) : super(
         'node did not reach Running within $timeout '
         '(last state: ${lastState?.name ?? 'unknown'}'
         '${health.isEmpty ? '' : '; health: ${health.join('; ')}'})',
       );

  /// The timeout that elapsed.
  final Duration timeout;

  /// Last backend state observed, or `null` when none was reported.
  final BackendState? lastState;

  /// Health messages observed last, possibly empty.
  final List<String> health;
}

/// The IPN backend reported an error (`ErrMessage` on the IPN bus) or entered
/// a state the node cannot recover from, such as `InUseOtherUser`.
final class TailscaleBackendException extends TailscaleException {
  /// Creates the exception for [message], optionally with the [state].
  const TailscaleBackendException(super.message, {this.state});

  /// Backend state when the error was observed, if known.
  final BackendState? state;
}

/// A LocalAPI request returned a non-success HTTP status.
final class LocalApiException extends TailscaleException {
  /// Creates the exception for [method] [path] returning [statusCode].
  LocalApiException(this.method, this.path, this.statusCode, this.body)
    : super('$method $path failed with HTTP $statusCode: ${body.trim()}');

  /// HTTP method.
  final String method;

  /// Request path (with query).
  final String path;

  /// Response status code.
  final int statusCode;

  /// Response body.
  final String body;
}

/// The Tailscale API rejected an OAuth client credential exchange.
final class TailscaleOAuthException extends TailscaleException {
  /// Creates the exception.
  TailscaleOAuthException(this.step, this.statusCode, this.body)
    : super('$step failed with HTTP $statusCode: ${body.trim()}');

  /// Which step failed: `token` or `create-key`.
  final String step;

  /// HTTP status returned by the API.
  final int statusCode;

  /// Response body.
  final String body;
}

/// The SOCKS5 proxy on the node's loopback listener refused a connection.
final class Socks5Exception extends TailscaleException {
  /// Creates the exception for [replyCode] (RFC 1928 §6), or `-1` for a
  /// protocol violation described by [message].
  const Socks5Exception(super.message, {this.replyCode = -1});

  /// RFC 1928 reply code, or `-1` for protocol errors.
  final int replyCode;
}

/// The operation is not supported in the current configuration, e.g. Funnel
/// on a Headscale control server.
final class TailscaleUnsupportedException extends TailscaleException {
  /// Creates the exception.
  const TailscaleUnsupportedException(super.message);
}
