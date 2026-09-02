// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Hermetic end-to-end tests: two nodes join an in-process control server
/// (no network, no account) and talk to each other.
///
/// Requirements: Go >= 1.25.5, a `hook/local_config.json` containing
/// `{"build_from_source": true, "build_test_control": true}`, and
/// `LIBTAILSCALE_INTEGRATION=1 dart test -t integration`.
@Tags(['integration', 'native'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libtailscale/libtailscale.dart';
import 'package:libtailscale/src/testing/tstestcontrol.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['LIBTAILSCALE_INTEGRATION'] == '1';
  late Directory temp;
  late Uri controlUrl;
  final nodes = <TailscaleNode>[];

  setUpAll(() {
    if (!enabled) return;
    if (!testControlAvailable) {
      fail(
        'tstestcontrol asset missing: set build_test_control in '
        'hook/local_config.json',
      );
    }
    controlUrl = Uri.parse(runTestControl());
  });

  tearDownAll(() {
    if (enabled) stopTestControl();
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('libtailscale-hermetic');
  });

  tearDown(() async {
    for (final n in nodes) {
      await n.close();
    }
    nodes.clear();
    await temp.delete(recursive: true);
  });

  Future<TailscaleNode> join(String name) async {
    // The test control server approves every node without a key, so the
    // "interactive" credential completes on its own.
    final node = TailscaleNode(
      TailscaleConfig(
        controlUrl: controlUrl,
        credential: const TailscaleCredential.interactive(),
        hostname: name,
        stateDir: '${temp.path}/$name',
        ephemeral: true,
      ),
    );
    nodes.add(node);
    await node.start();
    await node.waitUntilRunning(timeout: const Duration(seconds: 60));
    return node;
  }

  // A `test(name, body, skip: ...)` call with the closure inline is formatted
  // differently by Dart 3.12 and 3.13; keeping the closure last avoids that.
  void integrationTest(String name, Future<void> Function() body) {
    test(name, body, skip: enabled ? null : 'set LIBTAILSCALE_INTEGRATION=1');
  }

  integrationTest('two nodes reach Running with addresses', () async {
    final a = await join('node-a');
    final b = await join('node-b');
    expect(a.addresses.ipv4, isNotNull);
    expect(b.addresses.ipv4, isNotNull);
    expect(a.addresses.ipv4, isNot(b.addresses.ipv4));
    final status = await a.status();
    expect(status.isRunning, isTrue);
    expect(status.self!.hostName, 'node-a');
  });

  integrationTest(
    'listen/accept and dial/connect exchange bytes both ways',
    () async {
      final a = await join('node-a');
      final b = await join('node-b');
      final server = await a.listen(port: 8081);
      // Single-subscription stream, like dart:io's ServerSocket.
      final accepted = [
        Completer<TailscaleSocket>(),
        Completer<TailscaleSocket>(),
      ];
      var acceptedCount = 0;
      server.listen((socket) => accepted[acceptedCount++].complete(socket));

      // fd path
      final dialed = await b.dial(a.addresses.ipv4!.address, 8081);
      final serverSide = await accepted[0].future.timeout(
        const Duration(seconds: 30),
      );
      expect(serverSide.remoteAddress, b.addresses.ipv4);
      final fromClient = <int>[];
      serverSide.listen(fromClient.addAll);
      dialed.write('hello');
      await dialed.flush();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(utf8.decode(fromClient), 'hello');
      final fromServer = <int>[];
      final clientDone = Completer<void>();
      dialed.listen(fromServer.addAll, onDone: clientDone.complete);
      serverSide.write('world');
      await serverSide.close();
      await clientDone.future.timeout(const Duration(seconds: 30));
      expect(utf8.decode(fromServer), 'world');
      await dialed.close();

      // SOCKS5 path yields a dart:io Socket
      final socket = await b.connect(a.addresses.ipv4!.address, 8081);
      final side2 = await accepted[1].future.timeout(
        const Duration(seconds: 30),
      );
      side2.write('ping');
      await side2.close();
      expect(
        utf8.decode(
          await socket.fold<List<int>>([], (acc, c) => acc..addAll(c)),
        ),
        'ping',
      );
      socket.destroy();
      await server.close();
    },
  );

  integrationTest('whoIs identifies the peer', () async {
    final a = await join('node-a');
    final b = await join('node-b');
    final who = await a.whoIs(b.addresses.ipv4!.address);
    expect(who.node.shortName, 'node-b');
  });
}
