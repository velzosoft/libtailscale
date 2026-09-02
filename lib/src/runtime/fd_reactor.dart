// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io' show OSError, SocketException;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ffi/libc.dart';
import '../ffi/tailscale_api.dart';

/// Accepts a queued connection on a libtailscale listener fd.
///
/// Runs on the reactor isolate, so it must be a top-level or static function
/// (or a closure that captures only sendable values). Returns the connection
/// fd and the remote IP.
typedef AcceptFunction =
    ({int fd, String remoteAddress}) Function(int serverHandle, int listenerFd);

/// The default [AcceptFunction]: `tailscale_accept` + `tailscale_getremoteaddr`.
({int fd, String remoteAddress}) ffiAccept(int serverHandle, int listenerFd) {
  const api = FfiTailscale();
  final fd = api.accept(serverHandle, listenerFd);
  String remote;
  try {
    remote = api.remoteAddress(listenerFd, fd);
  } catch (_) {
    remote = '';
  }
  return (fd: fd, remoteAddress: remote);
}

/// A connection accepted by a [ReactorListener].
final class AcceptedConnection {
  /// Creates the record.
  const AcceptedConnection(this.connection, this.remoteAddress);

  /// The registered connection.
  final ReactorConnection connection;

  /// Remote tailnet IP as reported by libtailscale (may be empty).
  final String remoteAddress;
}

/// Drives the file descriptors handed out by libtailscale with a single
/// `poll(2)` loop on a dedicated isolate.
///
/// The Go side of libtailscale copies bytes between a tailnet connection and
/// one end of a socketpair; this class owns the other end. Reads are delivered
/// as [Uint8List] chunks, writes are attempted inline and queued behind
/// `POLLOUT` on `EAGAIN`, half-close maps to `shutdown(SHUT_WR)`, and closing
/// an fd tells Go to tear down the tailnet connection or listener.
///
/// Commands travel over a [SendPort]; a self-pipe wakes the blocked `poll`.
final class FdReactor {
  /// Creates a reactor. [accept] is used for listener fds; tests inject a
  /// function that does not need libtailscale.
  FdReactor({AcceptFunction accept = ffiAccept, String? debugName})
    : _accept = accept,
      _debugName = debugName ?? 'libtailscale-reactor';

  final AcceptFunction _accept;
  final String _debugName;

  final _connections = <int, ReactorConnection>{};
  final _listeners = <int, ReactorListener>{};
  final _receivePort = ReceivePort();
  final _stopped = Completer<void>();
  final _ready = Completer<void>();
  StreamSubscription<Object?>? _subscription;
  SendPort? _sendPort;
  Isolate? _isolate;
  int _wakeWriteFd = -1;
  int _wakeReadFd = -1;
  Pointer<Uint8>? _wakeByte;
  bool _started = false;
  bool _closed = false;

  /// Whether [start] completed and [close] has not been called.
  bool get isRunning => _started && !_closed;

  /// Registered connection count (for tests and diagnostics).
  int get connectionCount => _connections.length;

  /// Registered listener count (for tests and diagnostics).
  int get listenerCount => _listeners.length;

  /// Spawns the reactor isolate.
  Future<void> start() async {
    if (_started) throw StateError('FdReactor already started');
    _started = true;
    final (readFd, writeFd) = Libc.pipe();
    _wakeReadFd = readFd;
    _wakeWriteFd = writeFd;
    Libc.setNonBlocking(readFd);
    Libc.setNonBlocking(writeFd);
    _wakeByte = calloc<Uint8>(1)..value = 1;

    _subscription = _receivePort.listen(_onMessage);
    _isolate = await Isolate.spawn<_ReactorInit>(
      _reactorMain,
      _ReactorInit(_receivePort.sendPort, readFd, _accept),
      debugName: _debugName,
      errorsAreFatal: true,
      onError: _receivePort.sendPort,
      onExit: _receivePort.sendPort,
    );
    await _ready.future;
  }

  /// Registers a connection fd (from `tailscale_dial`, a log pipe, …).
  ///
  /// The fd is switched to non-blocking mode and owned by the reactor from
  /// now on: close it through the returned [ReactorConnection].
  ReactorConnection addConnection(int fd) {
    _ensureRunning();
    if (_connections.containsKey(fd)) {
      throw ArgumentError.value(fd, 'fd', 'already registered');
    }
    Libc.setNonBlocking(fd);
    final conn = ReactorConnection._(this, fd);
    _connections[fd] = conn;
    _send(['add_conn', fd]);
    return conn;
  }

  /// Registers a listener fd from `tailscale_listen`.
  ReactorListener addListener(int fd, {required int serverHandle}) {
    _ensureRunning();
    if (_listeners.containsKey(fd)) {
      throw ArgumentError.value(fd, 'fd', 'already registered');
    }
    final listener = ReactorListener._(this, fd);
    _listeners[fd] = listener;
    _send(['add_listener', fd, serverHandle]);
    return listener;
  }

  /// Stops the isolate, closing every registered fd.
  Future<void> close() async {
    if (_closed) return _stopped.future;
    _closed = true;
    if (_sendPort != null) {
      _send(['stop']);
      await _stopped.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => _isolate?.kill(priority: Isolate.immediate),
      );
    }
    for (final conn in _connections.values.toList()) {
      conn._onClosed();
    }
    for (final listener in _listeners.values.toList()) {
      listener._onClosed();
    }
    _connections.clear();
    _listeners.clear();
    await _subscription?.cancel();
    _receivePort.close();
    if (_wakeWriteFd >= 0) Libc.close(_wakeWriteFd);
    if (_wakeReadFd >= 0) Libc.close(_wakeReadFd);
    _wakeWriteFd = _wakeReadFd = -1;
    if (_wakeByte != null) {
      calloc.free(_wakeByte!);
      _wakeByte = null;
    }
    if (!_stopped.isCompleted) _stopped.complete();
  }

  void _ensureRunning() {
    if (!_started) throw StateError('FdReactor not started');
    if (_closed) throw StateError('FdReactor closed');
  }

  void _send(List<Object?> command) {
    final port = _sendPort;
    if (port == null) throw StateError('FdReactor not ready');
    port.send(command);
    // One wake byte per command; the loop counts them to know how many
    // commands to wait for after poll returns.
    Libc.write(_wakeWriteFd, _wakeByte!, 1);
  }

  void _onMessage(Object? message) {
    if (message is! List || message.isEmpty) {
      // Isolate error/exit notifications from the spawn ports.
      if (message == null) {
        _failAll(const SocketException('reactor isolate exited'));
      } else if (message is List && message.length == 2) {
        _failAll(SocketException('reactor isolate error: ${message[0]}'));
      }
      return;
    }
    switch (message[0]) {
      case 'port':
        _sendPort = message[1] as SendPort;
      case 'ready':
        if (!_ready.isCompleted) _ready.complete();
      case 'data':
        _connections[message[1] as int]?._onData(
          (message[2] as TransferableTypedData).materialize(),
        );
      case 'eof':
        _connections[message[1] as int]?._onEof();
      case 'error':
        _connections[message[1] as int]?._onError(
          message[2] as int,
          message[3] as String,
        );
      case 'flushed':
        _connections[message[1] as int]?._onFlushed(message[2] as int);
      case 'closed':
        final fd = message[1] as int;
        _connections.remove(fd)?._onClosed();
        _listeners.remove(fd)?._onClosed();
      case 'accepted':
        final listener = _listeners[message[1] as int];
        final fd = message[2] as int;
        final conn = ReactorConnection._(this, fd);
        _connections[fd] = conn;
        if (listener == null) {
          conn.close();
        } else {
          listener._onAccepted(AcceptedConnection(conn, message[3] as String));
        }
      case 'accept_error':
        _listeners[message[1] as int]?._onError(message[2] as String);
      case 'fatal':
        _failAll(SocketException('reactor failed: ${message[1]}'));
      case 'stopped':
        if (!_stopped.isCompleted) _stopped.complete();
    }
  }

  void _failAll(Object error) {
    for (final conn in _connections.values.toList()) {
      conn._onError(-1, error.toString());
    }
    for (final listener in _listeners.values.toList()) {
      listener._onError(error.toString());
    }
    if (!_ready.isCompleted) _ready.completeError(error);
    if (!_stopped.isCompleted) _stopped.complete();
  }
}

/// A connection fd managed by an [FdReactor].
final class ReactorConnection {
  ReactorConnection._(this._reactor, this.fd) {
    _controller = StreamController<Uint8List>(
      onPause: () => _sendIfOpen(['pause', fd]),
      onResume: () => _sendIfOpen(['resume', fd]),
      onCancel: () => _sendIfOpen(['pause', fd]),
    );
  }

  final FdReactor _reactor;

  /// The file descriptor.
  final int fd;

  late final StreamController<Uint8List> _controller;
  final _flushes = <int, Completer<void>>{};
  final _done = Completer<void>();
  int _nextToken = 0;
  bool _writeClosed = false;
  bool _closed = false;
  bool _readEof = false;

  /// Incoming bytes; closes on EOF. Errors are [SocketException]s.
  Stream<Uint8List> get data => _controller.stream;

  /// Completes when the fd has been closed (by us, by EOF+half-close, or by
  /// an error).
  Future<void> get done => _done.future;

  /// Whether [close] has completed.
  bool get isClosed => _closed;

  /// Whether the peer has finished sending.
  bool get readClosed => _readEof;

  /// Whether [shutdownWrite] or [close] was called.
  bool get writeClosed => _writeClosed;

  /// Queues [bytes] for writing. Completion is signalled through [flush].
  void write(List<int> bytes) {
    if (_closed || _writeClosed) {
      throw StateError('connection fd $fd is closed for writing');
    }
    if (bytes.isEmpty) return;
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    _reactor._send([
      'write',
      fd,
      TransferableTypedData.fromList([data]),
    ]);
  }

  /// Completes once every byte written so far has been handed to the kernel.
  Future<void> flush() {
    if (_closed) return Future.value();
    final token = _nextToken++;
    final completer = Completer<void>();
    _flushes[token] = completer;
    _reactor._send(['flush', fd, token]);
    return completer.future;
  }

  /// Half-closes: after pending writes drain, `shutdown(fd, SHUT_WR)` tells
  /// the Go side to `CloseWrite` the tailnet connection.
  void shutdownWrite() {
    if (_closed || _writeClosed) return;
    _writeClosed = true;
    _reactor._send(['shutdown_write', fd]);
  }

  /// Closes the fd immediately (pending writes are discarded).
  Future<void> close() {
    if (_closed) return _done.future;
    _writeClosed = true;
    if (_reactor.isRunning) {
      _reactor._send(['close', fd]);
    } else {
      _onClosed();
    }
    return _done.future;
  }

  void _sendIfOpen(List<Object?> command) {
    if (!_closed && _reactor.isRunning) _reactor._send(command);
  }

  void _onData(ByteBuffer buffer) {
    if (!_controller.isClosed) _controller.add(buffer.asUint8List());
  }

  void _onEof() {
    _readEof = true;
    if (!_controller.isClosed) _controller.close();
  }

  void _onError(int errno, String message) {
    if (!_controller.isClosed) {
      _controller.addError(
        SocketException(message, osError: OSError(message, errno)),
      );
      _controller.close();
    }
    _failFlushes(SocketException(message, osError: OSError(message, errno)));
  }

  void _onFlushed(int token) => _flushes.remove(token)?.complete();

  void _onClosed() {
    if (_closed) return;
    _closed = true;
    _writeClosed = true;
    _reactor._connections.remove(fd);
    if (!_controller.isClosed) _controller.close();
    _failFlushes(SocketException('connection fd $fd closed'));
    if (!_done.isCompleted) _done.complete();
  }

  void _failFlushes(Object error) {
    for (final c in _flushes.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _flushes.clear();
  }
}

/// A listener fd managed by an [FdReactor].
final class ReactorListener {
  ReactorListener._(this._reactor, this.fd);

  final FdReactor _reactor;

  /// The listener file descriptor.
  final int fd;

  final _controller = StreamController<AcceptedConnection>();
  final _done = Completer<void>();
  bool _closed = false;

  /// Accepted connections. Errors are [SocketException]s.
  Stream<AcceptedConnection> get connections => _controller.stream;

  /// Completes when the listener fd is closed.
  Future<void> get done => _done.future;

  /// Whether the listener is closed.
  bool get isClosed => _closed;

  /// Closes the listener; Go tears down the tailnet listener in response.
  Future<void> close() {
    if (_closed) return _done.future;
    if (_reactor.isRunning) {
      _reactor._send(['close', fd]);
    } else {
      _onClosed();
    }
    return _done.future;
  }

  void _onAccepted(AcceptedConnection accepted) {
    if (_controller.isClosed) {
      accepted.connection.close();
    } else {
      _controller.add(accepted);
    }
  }

  void _onError(String message) {
    if (!_controller.isClosed) _controller.addError(SocketException(message));
  }

  void _onClosed() {
    if (_closed) return;
    _closed = true;
    _reactor._listeners.remove(fd);
    if (!_controller.isClosed) _controller.close();
    if (!_done.isCompleted) _done.complete();
  }
}

// ---------------------------------------------------------------------------
// Reactor isolate
// ---------------------------------------------------------------------------

final class _ReactorInit {
  const _ReactorInit(this.owner, this.wakeReadFd, this.accept);
  final SendPort owner;
  final int wakeReadFd;
  final AcceptFunction accept;
}

Future<void> _reactorMain(_ReactorInit init) async {
  final loop = _ReactorLoop(init);
  await loop.run();
}

sealed class _QueueItem {}

final class _PendingWrite extends _QueueItem {
  _PendingWrite(this.ptr, this.length);
  final Pointer<Uint8> ptr;
  final int length;
  int offset = 0;
}

final class _PendingFlush extends _QueueItem {
  _PendingFlush(this.token);
  final int token;
}

final class _PendingShutdown extends _QueueItem {}

final class _Conn {
  _Conn(this.fd);
  final int fd;
  final queue = Queue<_QueueItem>();
  bool paused = false;
  bool readEof = false;
  bool writeShut = false;

  bool get wantsWrite => queue.isNotEmpty;

  void freeQueue() {
    for (final item in queue) {
      if (item is _PendingWrite) malloc.free(item.ptr);
    }
    queue.clear();
  }
}

final class _Listener {
  _Listener(this.fd, this.serverHandle);
  final int fd;
  final int serverHandle;
}

final class _ReactorLoop {
  _ReactorLoop(this._init) : _owner = _init.owner;

  static const _readBufferSize = 64 * 1024;

  final _ReactorInit _init;
  final SendPort _owner;
  final _commands = Queue<List<Object?>>();
  final _conns = <int, _Conn>{};
  final _listeners = <int, _Listener>{};
  final _receivePort = ReceivePort();
  int _pendingCommands = 0;
  bool _stop = false;
  int _capacity = 16;
  late Pointer<PollFd> _pollFds = calloc<PollFd>(_capacity);
  final Pointer<Uint8> _readBuffer = malloc<Uint8>(_readBufferSize);

  Future<void> run() async {
    _receivePort.listen((message) {
      if (message is List<Object?>) _commands.add(message);
    });
    _owner.send(['port', _receivePort.sendPort]);
    _owner.send(['ready']);
    try {
      while (!_stop) {
        _pollOnce();
        if (_pendingCommands > 0 || _commands.isNotEmpty) {
          await _drainCommands();
        }
      }
    } catch (e, st) {
      _owner.send(['fatal', '$e\n$st']);
    } finally {
      _shutdown();
    }
  }

  Future<void> _drainCommands() async {
    while (_pendingCommands > 0 || _commands.isNotEmpty) {
      if (_commands.isEmpty) {
        // Let the event loop deliver the port messages that go with the
        // wake bytes we have already counted.
        await Future<void>.delayed(Duration.zero);
      }
      while (_commands.isNotEmpty) {
        _handle(_commands.removeFirst());
        _pendingCommands--;
        if (_stop) return;
      }
    }
  }

  void _pollOnce() {
    final count = 1 + _listeners.length + _conns.length;
    _ensureCapacity(count);
    var i = 0;
    _pollFds[i]
      ..fd = _init.wakeReadFd
      ..events = LibcConstants.pollIn
      ..revents = 0;
    i++;
    final listenerOrder = _listeners.values.toList(growable: false);
    for (final l in listenerOrder) {
      _pollFds[i]
        ..fd = l.fd
        ..events = LibcConstants.pollIn
        ..revents = 0;
      i++;
    }
    final connOrder = _conns.values.toList(growable: false);
    for (final c in connOrder) {
      var events = 0;
      if (!c.paused && !c.readEof) events |= LibcConstants.pollIn;
      if (c.wantsWrite) events |= LibcConstants.pollOut;
      _pollFds[i]
        ..fd = events == 0 ? -1 : c.fd
        ..events = events
        ..revents = 0;
      i++;
    }

    final rc = Libc.poll(_pollFds, count, -1);
    if (rc < 0) {
      final err = Libc.errno;
      if (err == LibcConstants.eintr || err == LibcConstants.eagain) return;
      throw LibcException('poll', err);
    }
    if (rc == 0) return;

    if (_pollFds[0].revents & LibcConstants.pollIn != 0) {
      final n = Libc.read(_init.wakeReadFd, _readBuffer, _readBufferSize);
      if (n > 0) _pendingCommands += n;
    }
    i = 1;
    for (final l in listenerOrder) {
      final revents = _pollFds[i++].revents;
      if (revents == 0 || !_listeners.containsKey(l.fd)) continue;
      if (revents & LibcConstants.pollIn != 0) {
        _acceptOne(l);
      } else if (revents &
              (LibcConstants.pollHup |
                  LibcConstants.pollErr |
                  LibcConstants.pollNval) !=
          0) {
        _closeListener(l.fd);
      }
    }
    for (final c in connOrder) {
      final revents = _pollFds[i++].revents;
      if (revents == 0 || !_conns.containsKey(c.fd)) continue;
      if (revents & LibcConstants.pollNval != 0) {
        _removeConn(c, notifyClosed: true);
        continue;
      }
      if (revents & LibcConstants.pollOut != 0) _drainQueue(c);
      if (!_conns.containsKey(c.fd)) continue;
      if (revents & (LibcConstants.pollIn | LibcConstants.pollHup) != 0) {
        _readOne(c);
      } else if (revents & LibcConstants.pollErr != 0) {
        _failConn(c, LibcConstants.econnreset, 'socket error (POLLERR)');
      }
    }
  }

  void _ensureCapacity(int count) {
    if (count <= _capacity) return;
    while (_capacity < count) {
      _capacity *= 2;
    }
    calloc.free(_pollFds);
    _pollFds = calloc<PollFd>(_capacity);
  }

  void _handle(List<Object?> command) {
    switch (command[0]) {
      case 'add_conn':
        final fd = command[1] as int;
        _conns[fd] = _Conn(fd);
      case 'add_listener':
        final fd = command[1] as int;
        _listeners[fd] = _Listener(fd, command[2] as int);
      case 'pause':
        _conns[command[1] as int]?.paused = true;
      case 'resume':
        _conns[command[1] as int]?.paused = false;
      case 'write':
        final conn = _conns[command[1] as int];
        final bytes = (command[2] as TransferableTypedData)
            .materialize()
            .asUint8List();
        if (conn == null || conn.writeShut) break;
        final ptr = malloc<Uint8>(bytes.length);
        ptr.asTypedList(bytes.length).setAll(0, bytes);
        conn.queue.add(_PendingWrite(ptr, bytes.length));
        _drainQueue(conn);
      case 'flush':
        final conn = _conns[command[1] as int];
        final token = command[2] as int;
        if (conn == null) break;
        conn.queue.add(_PendingFlush(token));
        _drainQueue(conn);
      case 'shutdown_write':
        final conn = _conns[command[1] as int];
        if (conn == null) break;
        conn.queue.add(_PendingShutdown());
        _drainQueue(conn);
      case 'close':
        final fd = command[1] as int;
        final conn = _conns[fd];
        if (conn != null) {
          _removeConn(conn, notifyClosed: true);
        } else if (_listeners.containsKey(fd)) {
          _closeListener(fd);
        } else {
          _owner.send(['closed', fd]);
        }
      case 'stop':
        _stop = true;
    }
  }

  void _readOne(_Conn c) {
    final n = Libc.read(c.fd, _readBuffer, _readBufferSize);
    if (n > 0) {
      _owner.send([
        'data',
        c.fd,
        TransferableTypedData.fromList([_readBuffer.asTypedList(n)]),
      ]);
      return;
    }
    if (n == 0) {
      c.readEof = true;
      _owner.send(['eof', c.fd]);
      if (c.writeShut && c.queue.isEmpty) _removeConn(c, notifyClosed: true);
      return;
    }
    final err = Libc.errno;
    if (err == LibcConstants.eagain || err == LibcConstants.eintr) return;
    _failConn(c, err, 'read failed: ${Libc.strerror(err)}');
  }

  /// Writes as much of the queue as the kernel accepts; stops on EAGAIN.
  void _drainQueue(_Conn c) {
    while (c.queue.isNotEmpty) {
      final item = c.queue.first;
      switch (item) {
        case _PendingWrite():
          final n = Libc.write(
            c.fd,
            item.ptr + item.offset,
            item.length - item.offset,
          );
          if (n < 0) {
            final err = Libc.errno;
            if (err == LibcConstants.eagain || err == LibcConstants.eintr) {
              return; // POLLOUT will bring us back.
            }
            _failConn(c, err, 'write failed: ${Libc.strerror(err)}');
            return;
          }
          item.offset += n;
          if (item.offset >= item.length) {
            malloc.free(item.ptr);
            c.queue.removeFirst();
          }
        case _PendingFlush():
          c.queue.removeFirst();
          _owner.send(['flushed', c.fd, item.token]);
        case _PendingShutdown():
          c.queue.removeFirst();
          if (!c.writeShut) {
            c.writeShut = true;
            Libc.shutdown(c.fd, LibcConstants.shutWr);
          }
          if (c.readEof) {
            _removeConn(c, notifyClosed: true);
            return;
          }
      }
    }
  }

  void _acceptOne(_Listener l) {
    try {
      final accepted = _init.accept(l.serverHandle, l.fd);
      Libc.setNonBlocking(accepted.fd);
      _conns[accepted.fd] = _Conn(accepted.fd);
      _owner.send(['accepted', l.fd, accepted.fd, accepted.remoteAddress]);
    } catch (e) {
      _owner.send(['accept_error', l.fd, e.toString()]);
      // A dead listener would spin the loop; a bad-handle error means Go has
      // already forgotten it.
      if (e.toString().contains('EBADF')) _closeListener(l.fd);
    }
  }

  void _failConn(_Conn c, int errno, String message) {
    _owner.send(['error', c.fd, errno, message]);
    _removeConn(c, notifyClosed: true);
  }

  void _removeConn(_Conn c, {required bool notifyClosed}) {
    _conns.remove(c.fd);
    c.freeQueue();
    Libc.close(c.fd);
    if (notifyClosed) _owner.send(['closed', c.fd]);
  }

  void _closeListener(int fd) {
    if (_listeners.remove(fd) == null) return;
    Libc.close(fd);
    _owner.send(['closed', fd]);
  }

  void _shutdown() {
    for (final c in _conns.values.toList()) {
      _removeConn(c, notifyClosed: false);
    }
    for (final fd in _listeners.keys.toList()) {
      _listeners.remove(fd);
      Libc.close(fd);
    }
    calloc.free(_pollFds);
    malloc.free(_readBuffer);
    _receivePort.close();
    _owner.send(['stopped']);
  }
}
