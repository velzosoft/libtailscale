// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../session.dart';
import 'node_command.dart';

/// Sends one line to a tailnet host and prints the reply.
final class SendCommand extends NodeCommand {
  SendCommand() {
    argParser
      ..addFlag(
        'fd',
        negatable: false,
        help:
            "Use libtailscale's file-descriptor dial path instead of the "
            'loopback SOCKS5 proxy.',
      )
      ..addOption(
        'wait',
        defaultsTo: '5',
        valueHelp: 'seconds',
        help: 'How long to wait for the reply before closing.',
      );
  }

  @override
  String get name => 'send';

  @override
  String get description =>
      'Connect to <host> <port> on the tailnet, send <message> and print the '
      'reply.';

  @override
  String get invocation => '${super.invocation} <host> <port> <message...>';

  @override
  Future<int> runWithNode(NodeSession session) async {
    final rest = argResults!.rest;
    if (rest.length < 3) usageException('expected <host> <port> <message>');
    final host = rest[0];
    final port = int.tryParse(rest[1]);
    if (port == null || port < 1 || port > 65535) {
      usageException('<port> must be 1..65535');
    }
    final message = rest.sublist(2).join(' ');
    final waitSeconds = int.tryParse(argResults!['wait'] as String) ?? 5;
    final wait = Duration(seconds: waitSeconds);
    final node = session.node;

    final Stream<List<int>> incoming;
    final IOSink sink;
    final Future<void> Function() destroy;
    if (argResults!['fd'] as bool) {
      final socket = await node.dial(host, port);
      incoming = socket;
      sink = socket;
      destroy = socket.destroy;
    } else {
      final socket = await node.connect(host, port);
      incoming = socket;
      sink = socket;
      destroy = () async => socket.destroy();
    }
    stderr.writeln('connected to $host:$port');

    final reply = BytesBuilder();
    final done = Completer<void>();
    incoming.listen(
      reply.add,
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    sink.write('$message\n');
    await sink.flush();
    try {
      await done.future.timeout(wait, onTimeout: () {});
    } on IOException catch (e) {
      stderr.writeln('read error: $e');
    }
    stdout.write(utf8.decode(reply.takeBytes(), allowMalformed: true));
    await destroy();
    return 0;
  }
}
