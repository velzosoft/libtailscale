// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Hand-written `dart:ffi` bindings to the handful of libc calls the runtime
/// needs to drive the file descriptors handed out by libtailscale.
///
/// The symbols are resolved in the running process (`LookupInProcess`), so no
/// shim library is shipped. Only the POSIX platforms libtailscale supports are
/// covered: macOS, iOS, Linux and Android.
@DefaultAsset('package:libtailscale/src/ffi/libc.dart')
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// `struct pollfd` from `<poll.h>`; identical layout on every supported OS.
final class PollFd extends Struct {
  /// File descriptor to poll (negative entries are ignored by `poll`).
  @Int()
  external int fd;

  /// Requested events.
  @Short()
  external int events;

  /// Returned events.
  @Short()
  external int revents;
}

@Native<IntPtr Function(Int, Pointer<Void>, Size)>(symbol: 'read', isLeaf: true)
external int _read(int fd, Pointer<Void> buf, int count);

@Native<IntPtr Function(Int, Pointer<Void>, Size)>(
  symbol: 'write',
  isLeaf: true,
)
external int _write(int fd, Pointer<Void> buf, int count);

@Native<Int Function(Int)>(symbol: 'close', isLeaf: true)
external int _close(int fd);

@Native<Int Function(Int, Int)>(symbol: 'shutdown', isLeaf: true)
external int _shutdown(int fd, int how);

// Deliberately *not* a leaf call: poll blocks for a long time and a leaf call
// would keep the whole isolate group from reaching a safepoint (GC stalls).
@Native<Int Function(Pointer<PollFd>, UintPtr, Int)>(symbol: 'poll')
external int _poll(Pointer<PollFd> fds, int nfds, int timeoutMillis);

@Native<Int Function(Pointer<Int>)>(symbol: 'pipe', isLeaf: true)
external int _pipe(Pointer<Int> fds);

@Native<Int Function(Int, Int, Int, Pointer<Int>)>(
  symbol: 'socketpair',
  isLeaf: true,
)
external int _socketpair(int domain, int type, int protocol, Pointer<Int> sv);

// fcntl is variadic; VarArgs makes the third argument follow the platform's
// variadic calling convention (it matters on Apple arm64).
@Native<Int Function(Int, Int, VarArgs<(Int,)>)>(symbol: 'fcntl', isLeaf: true)
external int _fcntl(int fd, int cmd, int arg);

@Native<Void Function(Pointer<Void>)>(symbol: 'free', isLeaf: true)
external void _free(Pointer<Void> ptr);

@Native<Pointer<Utf8> Function(Int)>(symbol: 'strerror', isLeaf: true)
external Pointer<Utf8> _strerror(int errnum);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(symbol: 'getenv', isLeaf: true)
external Pointer<Utf8> _getenv(Pointer<Utf8> name);

@Native<Int Function(Pointer<Utf8>, Pointer<Utf8>, Int)>(
  symbol: 'setenv',
  isLeaf: true,
)
external int _setenv(Pointer<Utf8> name, Pointer<Utf8> value, int overwrite);

@Native<Pointer<Int> Function()>(symbol: '__error', isLeaf: true)
external Pointer<Int> _errnoApple();

@Native<Pointer<Int> Function()>(symbol: '__errno_location', isLeaf: true)
external Pointer<Int> _errnoGlibc();

@Native<Pointer<Int> Function()>(symbol: '__errno', isLeaf: true)
external Pointer<Int> _errnoBionic();

final bool _isApple = Platform.isMacOS || Platform.isIOS;

/// Platform-dependent libc constants.
abstract final class LibcConstants {
  /// `POLLIN`.
  static const int pollIn = 0x001;

  /// `POLLOUT`.
  static const int pollOut = 0x004;

  /// `POLLERR`.
  static const int pollErr = 0x008;

  /// `POLLHUP`.
  static const int pollHup = 0x010;

  /// `POLLNVAL`.
  static const int pollNval = 0x020;

  /// `SHUT_RD`.
  static const int shutRd = 0;

  /// `SHUT_WR`.
  static const int shutWr = 1;

  /// `SHUT_RDWR`.
  static const int shutRdWr = 2;

  /// `AF_UNIX` / `AF_LOCAL`.
  static const int afUnix = 1;

  /// `SOCK_STREAM`.
  static const int sockStream = 1;

  /// `F_GETFL`.
  static const int fGetFl = 3;

  /// `F_SETFL`.
  static const int fSetFl = 4;

  /// `EINTR`.
  static const int eintr = 4;

  /// `EBADF`.
  static const int ebadf = 9;

  /// `EPIPE`.
  static const int epipe = 32;

  /// `ERANGE`.
  static const int erange = 34;

  /// `O_NONBLOCK` (0x4 on Apple platforms, 0x800 on Linux/Android).
  static final int oNonblock = _isApple ? 0x0004 : 0x800;

  /// `EAGAIN` / `EWOULDBLOCK` (35 on Apple platforms, 11 on Linux/Android).
  static final int eagain = _isApple ? 35 : 11;

  /// `ECONNRESET` (54 on Apple platforms, 104 on Linux/Android).
  static final int econnreset = _isApple ? 54 : 104;
}

/// Thin, documented wrappers around the raw symbols.
///
/// Every function mirrors its C counterpart: negative return values mean
/// failure and [errno] carries the reason. Wrapping them in a class (rather
/// than exposing bare top-level externals) keeps the call sites readable and
/// gives tests a single seam.
abstract final class Libc {
  /// The calling thread's `errno`.
  ///
  /// Only meaningful immediately after a failed call on the same isolate, with
  /// no `await` in between.
  static int get errno {
    if (_isApple) return _errnoApple().value;
    if (Platform.isAndroid) return _errnoBionic().value;
    return _errnoGlibc().value;
  }

  /// `strerror(3)` for [errnum].
  static String strerror(int errnum) => _strerror(errnum).toDartString();

  /// `read(2)`.
  static int read(int fd, Pointer<Uint8> buf, int count) =>
      _read(fd, buf.cast(), count);

  /// `write(2)`.
  static int write(int fd, Pointer<Uint8> buf, int count) =>
      _write(fd, buf.cast(), count);

  /// `close(2)`.
  static int close(int fd) => _close(fd);

  /// `getenv(3)`: the value of [name] in the process environment, or `null`.
  ///
  /// Unlike `Platform.environment` this is not a snapshot; it reflects
  /// [setenv] calls made after the VM started.
  static String? getenv(String name) {
    final cName = name.toNativeUtf8();
    try {
      final value = _getenv(cName);
      return value == nullptr ? null : value.toDartString();
    } finally {
      malloc.free(cName);
    }
  }

  /// `setenv(3)`; with [overwrite] false an existing value is kept.
  static void setenv(String name, String value, {bool overwrite = true}) {
    final cName = name.toNativeUtf8();
    final cValue = value.toNativeUtf8();
    try {
      if (_setenv(cName, cValue, overwrite ? 1 : 0) != 0) {
        throw LibcException('setenv($name)', errno);
      }
    } finally {
      malloc
        ..free(cName)
        ..free(cValue);
    }
  }

  /// `shutdown(2)`.
  static int shutdown(int fd, int how) => _shutdown(fd, how);

  /// `poll(2)`; [timeoutMillis] of `-1` blocks indefinitely.
  static int poll(Pointer<PollFd> fds, int nfds, int timeoutMillis) =>
      _poll(fds, nfds, timeoutMillis);

  /// `free(3)` for memory allocated by C code (e.g. `tailscale_status_json`).
  static void free(Pointer<NativeType> ptr) => _free(ptr.cast());

  /// `pipe(2)`; returns `(readFd, writeFd)`.
  static (int, int) pipe() {
    final fds = calloc<Int>(2);
    try {
      if (_pipe(fds) != 0) {
        throw LibcException('pipe', errno);
      }
      return (fds[0], fds[1]);
    } finally {
      calloc.free(fds);
    }
  }

  /// `socketpair(2)` of `AF_UNIX, SOCK_STREAM` sockets; returns both ends.
  ///
  /// Used by tests to emulate the socketpair ends libtailscale hands out.
  static (int, int) socketpair() {
    final fds = calloc<Int>(2);
    try {
      if (_socketpair(LibcConstants.afUnix, LibcConstants.sockStream, 0, fds) !=
          0) {
        throw LibcException('socketpair', errno);
      }
      return (fds[0], fds[1]);
    } finally {
      calloc.free(fds);
    }
  }

  /// Sets `O_NONBLOCK` on [fd].
  static void setNonBlocking(int fd) {
    final flags = _fcntl(fd, LibcConstants.fGetFl, 0);
    if (flags < 0) throw LibcException('fcntl(F_GETFL)', errno);
    if (_fcntl(fd, LibcConstants.fSetFl, flags | LibcConstants.oNonblock) < 0) {
      throw LibcException('fcntl(F_SETFL)', errno);
    }
  }
}

/// A failed libc call.
final class LibcException implements Exception {
  /// Creates an exception for [call] failing with [errno].
  LibcException(this.call, this.errno);

  /// The C function that failed, e.g. `pipe`.
  final String call;

  /// The `errno` value observed right after the call.
  final int errno;

  @override
  String toString() =>
      'LibcException: $call failed: ${Libc.strerror(errno)} (errno $errno)';
}
