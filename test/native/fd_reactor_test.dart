// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['native'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:libtailscale/src/ffi/libc.dart';
import 'package:libtailscale/src/runtime/fd_reactor.dart';
import 'package:test/test.dart';

/// Writes [bytes] to a blocking fd with libc.
void writeAll(int fd, List<int> bytes) {
  final buf = malloc<Uint8>(bytes.length);
  try {
    buf.asTypedList(bytes.length).setAll(0, bytes);
    var off = 0;
    while (off < bytes.length) {
      final n = Libc.write(fd, buf + off, bytes.length - off);
      if (n < 0) throw LibcException('write', Libc.errno);
      off += n;
    }
  } finally {
    malloc.free(buf);
  }
}

/// Reads up to [max] bytes from a blocking fd; empty list means EOF.
Uint8List readSome(int fd, [int max = 65536]) {
  final buf = malloc<Uint8>(max);
  try {
    final n = Libc.read(fd, buf, max);
    if (n < 0) throw LibcException('read', Libc.errno);
    return Uint8List.fromList(buf.asTypedList(n));
  } finally {
    malloc.free(buf);
  }
}

/// Test [AcceptFunction]: the "listener" is a socketpair end on which the test
/// writes the accepted fd as a little-endian int32.
({int fd, String remoteAddress}) fakeAccept(int serverHandle, int listenerFd) {
  final bytes = readSome(listenerFd, 4);
  if (bytes.length != 4) throw StateError('EBADF: listener gone');
  final fd = ByteData.sublistView(bytes).getInt32(0, Endian.little);
  return (fd: fd, remoteAddress: '100.64.0.$serverHandle');
}

void main() {
  late FdReactor reactor;

  setUp(() async {
    reactor = FdReactor(accept: fakeAccept, debugName: 'test-reactor');
    await reactor.start();
  });

  tearDown(() => reactor.close());

  test('delivers incoming bytes and writes outgoing bytes', () async {
    final (ours, theirs) = Libc.socketpair();
    final conn = reactor.addConnection(ours);
    final received = <int>[];
    final done = Completer<void>();
    conn.data.listen(received.addAll, onDone: done.complete);

    writeAll(theirs, utf8.encode('hello reactor'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(utf8.decode(received), 'hello reactor');

    conn.write(utf8.encode('pong'));
    await conn.flush();
    expect(utf8.decode(readSome(theirs)), 'pong');

    // Half-close: peer sees EOF, but can still write to us.
    conn.shutdownWrite();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(readSome(theirs), isEmpty, reason: 'EOF after SHUT_WR');
    writeAll(theirs, utf8.encode('!'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(utf8.decode(received), 'hello reactor!');

    // Peer closes: our stream ends and the fd is released.
    Libc.close(theirs);
    await done.future.timeout(const Duration(seconds: 2));
    await conn.done.timeout(const Duration(seconds: 2));
    expect(conn.isClosed, isTrue);
    expect(reactor.connectionCount, 0);
  });

  test(
    'moves a large payload with backpressure between two connections',
    () async {
      final (a, b) = Libc.socketpair();
      final source = reactor.addConnection(a);
      final sink = reactor.addConnection(b);
      final payload = Uint8List(4 * 1024 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i & 0xFF;
      }
      final received = BytesBuilder(copy: false);
      final done = Completer<void>();
      sink.data.listen(received.add, onDone: done.complete);

      const chunk = 256 * 1024;
      for (var off = 0; off < payload.length; off += chunk) {
        source.write(Uint8List.sublistView(payload, off, off + chunk));
      }
      await source.flush().timeout(const Duration(seconds: 10));
      source.shutdownWrite();
      await done.future.timeout(const Duration(seconds: 10));
      expect(received.length, payload.length);
      expect(received.toBytes(), payload);
      await source.close();
      await sink.close();
    },
  );

  test('close discards the connection and completes done', () async {
    final (ours, theirs) = Libc.socketpair();
    final conn = reactor.addConnection(ours);
    conn.data.listen((_) {});
    await conn.close();
    expect(conn.isClosed, isTrue);
    expect(readSome(theirs), isEmpty, reason: 'peer sees EOF');
    expect(() => conn.write([1]), throwsStateError);
    Libc.close(theirs);
  });

  test('pausing the stream stops reads until resumed', () async {
    final (ours, theirs) = Libc.socketpair();
    final conn = reactor.addConnection(ours);
    final received = <int>[];
    final sub = conn.data.listen(received.addAll);
    sub.pause();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    writeAll(theirs, [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, isEmpty);
    sub.resume();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, [1, 2, 3]);
    await sub.cancel();
    await conn.close();
    Libc.close(theirs);
  });

  test('accepts connections from a listener fd', () async {
    final (listenerFd, listenerPeer) = Libc.socketpair();
    final listener = reactor.addListener(listenerFd, serverHandle: 7);
    final accepted = Completer<AcceptedConnection>();
    listener.connections.listen(accepted.complete);

    final (connFd, connPeer) = Libc.socketpair();
    final fdBytes = ByteData(4)..setInt32(0, connFd, Endian.little);
    writeAll(listenerPeer, fdBytes.buffer.asUint8List());

    final result = await accepted.future.timeout(const Duration(seconds: 2));
    expect(result.remoteAddress, '100.64.0.7');
    expect(result.connection.fd, connFd);
    expect(reactor.connectionCount, 1);

    final received = <int>[];
    result.connection.data.listen(received.addAll);
    writeAll(connPeer, utf8.encode('hi'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(utf8.decode(received), 'hi');

    await listener.close();
    expect(listener.isClosed, isTrue);
    expect(readSome(listenerPeer), isEmpty, reason: 'listener fd closed');
    expect(reactor.listenerCount, 0);
    await result.connection.close();
    Libc.close(connPeer);
    Libc.close(listenerPeer);
  });

  test('reactor close fails open connections and rejects new ones', () async {
    final (ours, theirs) = Libc.socketpair();
    final conn = reactor.addConnection(ours);
    final done = Completer<void>();
    conn.data.listen((_) {}, onDone: done.complete);
    await reactor.close();
    await done.future.timeout(const Duration(seconds: 2));
    expect(conn.isClosed, isTrue);
    expect(() => reactor.addConnection(theirs), throwsStateError);
    expect(readSome(theirs), isEmpty);
    Libc.close(theirs);
  });

  test('write errors surface through flush and close the connection', () async {
    final (ours, theirs) = Libc.socketpair();
    final conn = reactor.addConnection(ours);
    Libc.close(theirs);
    // Writing to a socketpair whose peer is gone fails with EPIPE.
    final done = Completer<void>();
    conn.data.listen((_) {}, onError: (Object _) {}, onDone: done.complete);
    conn.write(List.filled(1024, 1));
    await expectLater(conn.flush(), throwsA(isA<SocketException>()));
    await done.future.timeout(const Duration(seconds: 2));
    await conn.done.timeout(const Duration(seconds: 2));
    expect(conn.isClosed, isTrue);
  });
}
