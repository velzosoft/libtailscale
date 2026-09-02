// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads exact byte counts from a socket stream.
final class ByteReader {
  ByteReader(Stream<Uint8List> stream) {
    _subscription = stream.listen(
      (chunk) {
        _buffer.add(chunk);
        _pump();
      },
      onDone: () {
        _done = true;
        _pump();
      },
      onError: (Object e, StackTrace st) {
        _error = e;
        _pump();
      },
    );
  }

  final BytesBuilder _buffer = BytesBuilder(copy: true);
  late final StreamSubscription<Uint8List> _subscription;
  bool _done = false;
  Object? _error;
  (int, Completer<Uint8List>)? _pending;

  Future<Uint8List> read(int n) {
    if (_pending != null) throw StateError('concurrent read');
    final completer = Completer<Uint8List>();
    _pending = (n, completer);
    _pump();
    return completer.future;
  }

  Future<int> readByte() async => (await read(1))[0];

  /// Remaining bytes as a stream, for piping after the handshake.
  Stream<Uint8List> detach() {
    final controller = StreamController<Uint8List>();
    if (_buffer.isNotEmpty) controller.add(_buffer.takeBytes());
    _subscription
      ..onData(controller.add)
      ..onDone(controller.close)
      ..onError(controller.addError);
    if (_done) controller.close();
    return controller.stream;
  }

  void _pump() {
    final pending = _pending;
    if (pending == null) return;
    final (n, completer) = pending;
    if (_error != null) {
      _pending = null;
      completer.completeError(_error!);
      return;
    }
    if (_buffer.length >= n) {
      final all = _buffer.takeBytes();
      _buffer.add(all.sublist(n));
      _pending = null;
      completer.complete(Uint8List.fromList(all.sublist(0, n)));
    } else if (_done) {
      _pending = null;
      completer.completeError(const SocketException('closed'));
    }
  }
}

/// A minimal SOCKS5 server for tests: optional username/password, CONNECT
/// only, targets resolved by [resolveTarget].
final class FakeSocks5Proxy {
  FakeSocks5Proxy({
    this.username,
    this.password,
    this.replyCode = 0,
    required this.resolveTarget,
  });

  final String? username;
  final String? password;

  /// Reply code to send instead of connecting (0 = connect normally).
  int replyCode;

  /// Opens the connection to the requested target.
  final Future<Socket> Function(String host, int port) resolveTarget;

  final requests = <(String host, int port)>[];
  final _clients = <Socket>[];
  late ServerSocket _server;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _server.close();
  }

  Future<void> _handle(Socket client) async {
    _clients.add(client);
    final reader = ByteReader(client);
    try {
      final ver = await reader.readByte();
      if (ver != 5) throw StateError('bad version $ver');
      final count = await reader.readByte();
      final methods = await reader.read(count);
      if (username != null) {
        if (!methods.contains(2)) {
          client.add([5, 0xFF]);
          await client.flush();
          client.destroy();
          return;
        }
        client.add([5, 2]);
        final authVer = await reader.readByte();
        if (authVer != 1) throw StateError('bad auth version');
        final ulen = await reader.readByte();
        final user = utf8.decode(await reader.read(ulen));
        final plen = await reader.readByte();
        final pass = utf8.decode(await reader.read(plen));
        if (user != username || pass != password) {
          client.add([1, 1]);
          await client.flush();
          client.destroy();
          return;
        }
        client.add([1, 0]);
      } else {
        client.add([5, 0]);
      }
      final header = await reader.read(4);
      if (header[0] != 5 || header[1] != 1) throw StateError('bad request');
      final String host;
      switch (header[3]) {
        case 1:
          host = InternetAddress.fromRawAddress(await reader.read(4)).address;
        case 4:
          host = InternetAddress.fromRawAddress(await reader.read(16)).address;
        case 3:
          final len = await reader.readByte();
          host = utf8.decode(await reader.read(len));
        default:
          throw StateError('bad atyp');
      }
      final portBytes = await reader.read(2);
      final port = (portBytes[0] << 8) | portBytes[1];
      requests.add((host, port));
      if (replyCode != 0) {
        client.add([5, replyCode, 0, 1, 0, 0, 0, 0, 0, 0]);
        await client.flush();
        client.destroy();
        return;
      }
      final target = await resolveTarget(host, port);
      client.add([5, 0, 0, 1, 127, 0, 0, 1, (port >> 8) & 0xFF, port & 0xFF]);
      unawaited(
        reader.detach().cast<List<int>>().pipe(target).catchError((_) {}),
      );
      unawaited(target.cast<List<int>>().pipe(client).catchError((_) {}));
    } catch (_) {
      client.destroy();
    }
  }
}

/// A TCP echo server that optionally greets with a banner.
final class EchoServer {
  EchoServer({this.banner});

  final String? banner;
  late ServerSocket _server;
  final _clients = <Socket>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      _clients.add(socket);
      if (banner != null) socket.write(banner);
      socket.listen(socket.add, onDone: socket.close, onError: (_) {});
    });
  }

  Future<void> close() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _server.close();
  }
}
