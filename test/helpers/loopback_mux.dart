// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:io';

/// Emulates tsnet's loopback listener, which serves SOCKS5 and the LocalAPI
/// on one port: the first byte decides (0x05 = SOCKS5, anything else HTTP)
/// and the connection is spliced to the matching backend port.
final class LoopbackMux {
  LoopbackMux({required this.socksPort, required this.httpPort});

  final int socksPort;
  final int httpPort;
  late ServerSocket _server;
  final _sockets = <Socket>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }

  Future<void> _handle(Socket client) async {
    _sockets.add(client);
    // Handed to the backend splice; closed with the sockets.
    // ignore: cancel_subscriptions
    late StreamSubscription<List<int>> sub;
    sub = client.listen(
      (first) async {
        sub.pause();
        final backendPort = first.isNotEmpty && first[0] == 5
            ? socksPort
            : httpPort;
        try {
          final backend = await Socket.connect(
            InternetAddress.loopbackIPv4,
            backendPort,
          );
          _sockets.add(backend);
          backend.add(first);
          sub
            ..onData(backend.add)
            ..onDone(() => backend.close().catchError((_) {}))
            ..onError((Object _) => backend.destroy())
            ..resume();
          unawaited(backend.cast<List<int>>().pipe(client).catchError((_) {}));
        } catch (_) {
          client.destroy();
        }
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }
}
