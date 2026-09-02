// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:libtailscale/libtailscale.dart';

import '../session.dart';
import 'node_command.dart';

/// Runs an echo (chat) service on the tailnet.
final class EchoCommand extends NodeCommand {
  EchoCommand() {
    argParser.addOption(
      'port',
      defaultsTo: '7777',
      valueHelp: 'port',
      help: 'TCP port to listen on.',
    );
  }

  @override
  String get name => 'echo';

  @override
  String get description =>
      'Listen on a tailnet port, echo every byte back and print incoming '
      'lines with the sender until Ctrl-C.';

  @override
  Future<int> runWithNode(NodeSession session) async {
    final port = int.tryParse(argResults!['port'] as String);
    if (port == null || port < 1 || port > 65535) {
      usageException('--port must be 1..65535');
    }
    final node = session.node;
    final server = await node.listen(port: port);
    stderr.writeln(
      'echo service listening on port $port; press Ctrl-C to stop',
    );
    final subscription = server.listen(
      (socket) => _serve(node, socket),
      onError: (Object e) => stderr.writeln('accept error: $e'),
    );
    await NodeSession.waitForInterrupt();
    await subscription.cancel();
    await server.close();
    return 0;
  }

  Future<void> _serve(TailscaleNode node, TailscaleSocket socket) async {
    final ip = socket.remoteAddress?.address ?? '?';
    var who = ip;
    if (socket.remoteAddress != null) {
      try {
        final identity = await node.whoIs(ip);
        who = '${identity.node.shortName} ($ip)';
      } on TailscaleException {
        // Unknown peer; keep the IP.
      }
    }
    stderr.writeln('connection from $who');
    final lines = StringBuffer();
    socket.listen(
      (chunk) {
        socket.add(chunk); // echo
        lines.write(utf8.decode(chunk, allowMalformed: true));
        var newline = lines.toString().indexOf('\n');
        while (newline >= 0) {
          final text = lines.toString();
          stdout.writeln('$who: ${text.substring(0, newline).trimRight()}');
          lines
            ..clear()
            ..write(text.substring(newline + 1));
          newline = lines.toString().indexOf('\n');
        }
      },
      onError: (Object e) => stderr.writeln('$who: read error: $e'),
      onDone: () {
        if (lines.isNotEmpty) stdout.writeln('$who: $lines');
        stderr.writeln('$who: disconnected');
        socket.close();
      },
    );
  }
}
