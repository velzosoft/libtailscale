// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// A headless Tailscale / Headscale node in about sixty lines.
///
/// Joins the tailnet with an auth key, prints this node and its peers, serves
/// an echo service on port 7777 and, when a peer is named on the command line,
/// sends it a line over the tailnet:
///
/// ```sh
/// TS_AUTHKEY=tskey-auth-… dart run example/example.dart [peer-host]
/// TS_CONTROL_URL=https://headscale.example.com TS_AUTHKEY=<pre-auth key> dart run example/example.dart
/// ```
///
/// Two of these talking to each other, or one plus `tsnode echo` from
/// `examples/tsnode/`, is a complete end-to-end test. The Flutter app in
/// `examples/node_console/` builds the same calls into a UI.
library;

import 'dart:convert';
import 'dart:io';

import 'package:libtailscale/libtailscale.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final authKey = env['TS_AUTHKEY'];
  if (authKey == null || authKey.isEmpty) {
    stderr.writeln(
      'Set TS_AUTHKEY to a Tailscale auth key or Headscale '
      'pre-auth key (and TS_CONTROL_URL for Headscale).',
    );
    exitCode = 64;
    return;
  }
  final controlUrl = env['TS_CONTROL_URL']; // null selects Tailscale

  // 1. Configure: control server, credential, hostname, where the node key
  //    lives. Ephemeral nodes disappear from the tailnet when they close.
  final node = TailscaleNode(
    TailscaleConfig(
      controlUrl: controlUrl == null ? null : Uri.parse(controlUrl),
      credential: TailscaleCredential.authKey(authKey),
      hostname: 'libtailscale-example',
      stateDir:
          env['TS_STATE_DIR'] ??
          '${Directory.systemTemp.path}/libtailscale-example',
      ephemeral: true,
    ),
  );

  // 2. Control: start, follow the backend state, wait for connectivity.
  final states = node.stateChanges.listen(
    (state) => stdout.writeln('state: ${state.wireName}'),
  );
  await node.start();
  await node.waitUntilRunning(timeout: const Duration(seconds: 60));
  stdout.writeln('running as ${node.addresses.ipv4?.address}');

  // 3. Observe: this node, the tailnet and its peers.
  final status = await node.status();
  stdout.writeln(
    '${status.self?.magicDnsName} on ${status.currentTailnet?.name}, '
    '${status.peers.length} peer(s)',
  );
  for (final peer in status.peers) {
    stdout.writeln(
      '  ${peer.name} ${peer.ipv4 ?? '-'} '
      '${peer.online ? 'online' : 'offline'} ${peer.os}',
    );
  }

  // 4. Serve: accept tailnet connections and echo lines back, naming the
  //    sender through whoIs.
  final server = await node.listen(port: 7777);
  server.listen((socket) async {
    var who = socket.remoteAddress?.address ?? 'peer';
    try {
      who = (await node.whoIs(who)).node.shortName;
    } on TailscaleException {
      // Not a tailnet peer we know; keep the address.
    }
    utf8.decoder.bind(socket).transform(const LineSplitter()).listen((line) {
      stdout.writeln('$who: $line');
      socket.writeln(line);
    }, onDone: socket.close);
  });
  stdout.writeln('echo service listening on port 7777');

  // 5. Operate: dial a peer by MagicDNS name or IP. connect() returns a real
  //    dart:io Socket through the node's SOCKS5 proxy; httpClient() does the
  //    same for HTTP, WebSockets and gRPC.
  if (args.isNotEmpty) {
    final socket = await node.connect(args.first, 7777);
    socket.writeln('hello from ${node.config.hostname}');
    await socket.flush();
    final reply = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    stdout.writeln('${args.first} replied: $reply');
    await socket.close();
  }

  // 6. Shut down cleanly on Ctrl-C.
  stdout.writeln('press Ctrl-C to stop');
  await ProcessSignal.sigint.watch().first;
  await states.cancel();
  await server.close();
  await node.close();
}
