// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../api/exceptions.dart';
import 'libc.dart';
import 'tailscale_bindings.g.dart' as c;

/// Result of `tailscale_loopback`: the loopback listener that serves both a
/// SOCKS5 proxy and the LocalAPI.
final class LoopbackInfo {
  /// Creates the info.
  const LoopbackInfo({
    required this.host,
    required this.port,
    required this.proxyCredential,
    required this.localApiCredential,
  });

  /// Parses `host:port` as written by `tailscale_loopback`.
  factory LoopbackInfo.parse(
    String address, {
    required String proxyCredential,
    required String localApiCredential,
  }) {
    final colon = address.lastIndexOf(':');
    if (colon < 0) {
      throw FormatException('expected host:port', address);
    }
    var host = address.substring(0, colon);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    final port = int.tryParse(address.substring(colon + 1));
    if (port == null) {
      throw FormatException('invalid port', address);
    }
    return LoopbackInfo(
      host: host,
      port: port,
      proxyCredential: proxyCredential,
      localApiCredential: localApiCredential,
    );
  }

  /// Loopback host, normally `127.0.0.1`.
  final String host;

  /// Loopback TCP port.
  final int port;

  /// SOCKS5 password (the username is always `tsnet`).
  final String proxyCredential;

  /// LocalAPI basic-auth password (the username is empty).
  final String localApiCredential;

  /// `host:port`.
  String get address => '$host:$port';

  @override
  String toString() => 'LoopbackInfo($address)';
}

/// The raw C API of libtailscale with Dart-friendly types and error handling.
///
/// Handles and file descriptors are plain integers, so they can be passed
/// between isolates. Methods marked *blocking* may block the calling OS
/// thread for a long time and must be run through a `NativeWorker`.
///
/// This is an interface so that the runtime above it can be unit-tested with
/// a fake; [FfiTailscale] is the real implementation.
abstract interface class NativeTailscale {
  /// `tailscale_new`: allocates a server handle. Never fails.
  int newServer();

  /// `tailscale_start` (*blocking*: does file and network I/O).
  void start(int sd);

  /// `tailscale_up` (*blocking until Running and not cancellable*).
  void up(int sd);

  /// `tailscale_close`. Does not close listeners or connections.
  void close(int sd);

  /// `tailscale_set_dir`.
  void setDir(int sd, String dir);

  /// `tailscale_set_hostname`.
  void setHostname(int sd, String hostname);

  /// `tailscale_set_authkey`.
  void setAuthKey(int sd, String authKey);

  /// `tailscale_set_control_url`.
  void setControlUrl(int sd, String controlUrl);

  /// `tailscale_set_ephemeral`.
  void setEphemeral(int sd, bool ephemeral);

  /// `tailscale_set_logfd`; `-1` discards logs.
  void setLogFd(int sd, int fd);

  /// `tailscale_getips`: the raw `<ip4>,<ip6>` string.
  String getIps(int sd);

  /// `tailscale_dial` (*blocking*): returns a connection fd.
  int dial(int sd, String network, String address);

  /// `tailscale_listen`: returns a listener fd that becomes readable when a
  /// connection is waiting to be accepted.
  int listen(int sd, String network, String address);

  /// `tailscale_accept` (*blocking unless the listener fd was polled*).
  ///
  /// [sd] is only used to fetch the error message on failure.
  int accept(int sd, int listener);

  /// `tailscale_getremoteaddr`: the remote IP (without port) of [conn].
  String remoteAddress(int listener, int conn);

  /// `tailscale_loopback` (starts the server if needed).
  LoopbackInfo loopback(int sd);

  /// `tailscale_status_json` (*blocking*, up to 10 s).
  String statusJson(int sd);

  /// `tailscale_errmsg`.
  String errmsg(int sd);

  /// `tailscale_enable_funnel_to_localhost_plaintext_http1` (*blocking*).
  ///
  /// Callers must ensure the node has at least one cert domain first; the Go
  /// side indexes `CertDomains[0]` without a bounds check.
  void enableFunnelToLocalhostPlaintextHttp1(int sd, int localhostPort);
}

/// [NativeTailscale] implemented on top of the generated `dart:ffi` bindings.
final class FfiTailscale implements NativeTailscale {
  /// Creates the wrapper. It has no state and is safe to send to isolates.
  const FfiTailscale();

  static const _initialBufferSize = 256;
  static const _maxBufferSize = 1 << 20;
  static const _credentialLength = 32;

  @override
  int newServer() => c.tailscale_new();

  @override
  void start(int sd) => _check('tailscale_start', sd, c.tailscale_start(sd));

  @override
  void up(int sd) => _check('tailscale_up', sd, c.tailscale_up(sd));

  @override
  void close(int sd) => _check('tailscale_close', sd, c.tailscale_close(sd));

  @override
  void setDir(int sd, String dir) => _withCString(
    dir,
    (p) => _check('tailscale_set_dir', sd, c.tailscale_set_dir(sd, p)),
  );

  @override
  void setHostname(int sd, String hostname) => _withCString(
    hostname,
    (p) =>
        _check('tailscale_set_hostname', sd, c.tailscale_set_hostname(sd, p)),
  );

  @override
  void setAuthKey(int sd, String authKey) => _withCString(
    authKey,
    (p) => _check('tailscale_set_authkey', sd, c.tailscale_set_authkey(sd, p)),
  );

  @override
  void setControlUrl(int sd, String controlUrl) => _withCString(
    controlUrl,
    (p) => _check(
      'tailscale_set_control_url',
      sd,
      c.tailscale_set_control_url(sd, p),
    ),
  );

  @override
  void setEphemeral(int sd, bool ephemeral) => _check(
    'tailscale_set_ephemeral',
    sd,
    c.tailscale_set_ephemeral(sd, ephemeral ? 1 : 0),
  );

  @override
  void setLogFd(int sd, int fd) =>
      _check('tailscale_set_logfd', sd, c.tailscale_set_logfd(sd, fd));

  @override
  String getIps(int sd) => _readString(
    'tailscale_getips',
    sd,
    (buf, len) => c.tailscale_getips(sd, buf, len),
    initialSize: 128,
  );

  @override
  int dial(int sd, String network, String address) => _withCString(
    network,
    (net) => _withCString(
      address,
      (addr) => _outInt(
        (out) =>
            _check('tailscale_dial', sd, c.tailscale_dial(sd, net, addr, out)),
      ),
    ),
  );

  @override
  int listen(int sd, String network, String address) => _withCString(
    network,
    (net) => _withCString(
      address,
      (addr) => _outInt(
        (out) => _check(
          'tailscale_listen',
          sd,
          c.tailscale_listen(sd, net, addr, out),
        ),
      ),
    ),
  );

  @override
  int accept(int sd, int listener) => _outInt(
    (out) => _check('tailscale_accept', sd, c.tailscale_accept(listener, out)),
  );

  @override
  String remoteAddress(int listener, int conn) => _readString(
    'tailscale_getremoteaddr',
    // Errors are reported via errno codes only; no server handle needed.
    -1,
    (buf, len) => c.tailscale_getremoteaddr(listener, conn, buf, len),
    initialSize: 64,
  );

  @override
  LoopbackInfo loopback(int sd) {
    final proxy = calloc<Char>(_credentialLength + 1);
    final local = calloc<Char>(_credentialLength + 1);
    try {
      final address = _readString(
        'tailscale_loopback',
        sd,
        (buf, len) => c.tailscale_loopback(sd, buf, len, proxy, local),
        initialSize: 128,
      );
      return LoopbackInfo.parse(
        address,
        proxyCredential: proxy.cast<Utf8>().toDartString(),
        localApiCredential: local.cast<Utf8>().toDartString(),
      );
    } finally {
      calloc.free(proxy);
      calloc.free(local);
    }
  }

  @override
  String statusJson(int sd) {
    final out = calloc<Pointer<Char>>();
    try {
      _check('tailscale_status_json', sd, c.tailscale_status_json(sd, out));
      final ptr = out.value;
      if (ptr == nullptr) return '';
      try {
        return ptr.cast<Utf8>().toDartString();
      } finally {
        Libc.free(ptr);
      }
    } finally {
      calloc.free(out);
    }
  }

  @override
  String errmsg(int sd) {
    var size = _initialBufferSize;
    while (true) {
      final buf = calloc<Char>(size);
      try {
        final rc = c.tailscale_errmsg(sd, buf, size);
        if (rc == 0) return buf.cast<Utf8>().toDartString();
        if (rc == LibcConstants.erange && size < _maxBufferSize) {
          size *= 2;
          continue;
        }
        if (rc == LibcConstants.ebadf) return 'invalid tailscale handle';
        return 'tailscale_errmsg failed with code $rc';
      } finally {
        calloc.free(buf);
      }
    }
  }

  @override
  void enableFunnelToLocalhostPlaintextHttp1(int sd, int localhostPort) =>
      _check(
        'tailscale_enable_funnel_to_localhost_plaintext_http1',
        sd,
        c.tailscale_enable_funnel_to_localhost_plaintext_http1(
          sd,
          localhostPort,
        ),
      );

  // -- helpers ---------------------------------------------------------------

  /// Maps a C return code to an exception. `0` is success, `-1` means "see
  /// `tailscale_errmsg`", anything else is an errno value.
  void _check(String function, int sd, int rc) {
    if (rc == 0) return;
    if (rc == -1) {
      throw TailscaleNativeException(function, rc, errmsg(sd));
    }
    if (rc == LibcConstants.ebadf) {
      throw TailscaleClosedException('$function: invalid handle (EBADF)');
    }
    throw TailscaleNativeException(function, rc, Libc.strerror(rc));
  }

  R _withCString<R>(String value, R Function(Pointer<Char> ptr) body) {
    final ptr = value.toNativeUtf8();
    try {
      return body(ptr.cast());
    } finally {
      malloc.free(ptr);
    }
  }

  int _outInt(void Function(Pointer<Int> out) body) {
    final out = calloc<Int>();
    try {
      body(out);
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  /// Calls [fill] with a growing buffer until it no longer reports `ERANGE`.
  String _readString(
    String function,
    int sd,
    int Function(Pointer<Char> buf, int len) fill, {
    required int initialSize,
  }) {
    var size = initialSize;
    while (true) {
      final buf = calloc<Char>(size);
      try {
        final rc = fill(buf, size);
        if (rc == LibcConstants.erange && size < _maxBufferSize) {
          size *= 2;
          continue;
        }
        _check(function, sd, rc);
        return buf.cast<Utf8>().toDartString();
      } finally {
        calloc.free(buf);
      }
    }
  }
}
