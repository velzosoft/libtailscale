// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../runtime/fd_reactor.dart';

/// A TCP connection on the tailnet backed by a libtailscale file descriptor.
///
/// It is a `Stream<Uint8List>` for reading and an [IOSink] for writing, like
/// `dart:io`'s `Socket`, but it is deliberately *not* a `Socket`: Dart offers
/// no way to wrap a foreign fd in one. For a real `Socket` (including TLS)
/// use `TailscaleNode.connect`, which goes through the SOCKS5 proxy instead.
final class TailscaleSocket extends Stream<Uint8List> implements IOSink {
  /// Wraps a reactor connection. Library-internal.
  TailscaleSocket.fromConnection(
    this._connection, {
    required this.remoteAddress,
    this.remotePort,
  });

  final ReactorConnection _connection;

  /// The peer's tailnet IP, if known (accepted connections always know it;
  /// dialled connections know it when the target was an IP literal).
  final InternetAddress? remoteAddress;

  /// The peer's port, if known (only for dialled connections).
  final int? remotePort;

  Encoding _encoding = utf8;
  Future<void>? _addStream;

  /// The underlying file descriptor (diagnostics only).
  int get fd => _connection.fd;

  /// Whether the peer has finished sending (EOF received).
  bool get readClosed => _connection.readClosed;

  /// Whether the write side was closed.
  bool get writeClosed => _connection.writeClosed;

  // -- Stream<Uint8List> -----------------------------------------------------

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _connection.data.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  // -- IOSink ----------------------------------------------------------------

  @override
  Encoding get encoding => _encoding;

  @override
  set encoding(Encoding value) => _encoding = value;

  @override
  void add(List<int> data) {
    _checkNotAddingStream();
    _connection.write(data);
  }

  /// Not supported: a tailnet socket cannot deliver an error to the peer.
  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    throw UnsupportedError('TailscaleSocket.addError is not supported');
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _checkNotAddingStream();
    final completer = Completer<void>();
    _addStream = completer.future;
    late final StreamSubscription<List<int>> sub;
    sub = stream.listen(
      (chunk) {
        try {
          _connection.write(chunk);
        } catch (e, st) {
          sub.cancel();
          _addStream = null;
          completer.completeError(e, st);
        }
      },
      onError: (Object e, StackTrace st) {
        sub.cancel();
        _addStream = null;
        completer.completeError(e, st);
      },
      onDone: () {
        _addStream = null;
        completer.complete();
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  @override
  void write(Object? object) {
    final text = object.toString();
    if (text.isNotEmpty) add(_encoding.encode(text));
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    final buffer = StringBuffer();
    buffer.writeAll(objects, separator);
    write(buffer.toString());
  }

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  Future<void> flush() => _connection.flush();

  /// Finishes writing: flushes pending data and half-closes the connection.
  ///
  /// The peer sees EOF; reading continues until the peer closes too, after
  /// which the fd is released. Use [destroy] to drop everything immediately.
  @override
  Future<void> close() async {
    await _addStream;
    _connection.shutdownWrite();
    await _connection.flush().catchError((_) {});
  }

  /// Closes the connection in both directions right away.
  Future<void> destroy() => _connection.close();

  /// Completes when the connection is fully closed.
  @override
  Future<void> get done => _connection.done;

  void _checkNotAddingStream() {
    if (_addStream != null) {
      throw StateError('cannot add while addStream is in progress');
    }
  }

  @override
  String toString() =>
      'TailscaleSocket(fd: $fd, remote: ${remoteAddress?.address})';
}

/// A listening socket on the tailnet; emits a [TailscaleSocket] per accepted
/// connection.
final class TailscaleServerSocket extends Stream<TailscaleSocket> {
  /// Wraps a reactor listener. Library-internal.
  TailscaleServerSocket.fromListener(
    this._listener, {
    required this.port,
    required this.host,
  });

  final ReactorListener _listener;

  /// The port that was bound.
  final int port;

  /// The host that was bound (empty for all tailnet addresses).
  final String host;

  /// Completes when the listener is closed.
  Future<void> get done => _listener.done;

  /// Whether the listener is closed.
  bool get isClosed => _listener.isClosed;

  @override
  StreamSubscription<TailscaleSocket> listen(
    void Function(TailscaleSocket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _listener.connections
      .map(
        (accepted) => TailscaleSocket.fromConnection(
          accepted.connection,
          remoteAddress: InternetAddress.tryParse(accepted.remoteAddress),
        ),
      )
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  /// Stops listening. libtailscale tears down the tailnet listener when the
  /// fd closes; already-accepted connections stay open.
  Future<void> close() => _listener.close();

  @override
  String toString() => 'TailscaleServerSocket(port: $port)';
}
