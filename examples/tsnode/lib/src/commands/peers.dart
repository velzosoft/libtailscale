// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import '../format.dart';
import '../session.dart';
import 'node_command.dart';

/// Lists the peers visible to this node.
final class PeersCommand extends NodeCommand {
  PeersCommand() {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Print the raw peer objects instead of a table.',
    );
  }

  @override
  String get name => 'peers';

  @override
  String get description =>
      'List peers: name, IPs, online, OS, tags, last seen.';

  @override
  Future<int> runWithNode(NodeSession session) async {
    final status = await session.node.status();
    final peers = [...status.peers]..sort((a, b) => a.name.compareTo(b.name));
    if (argResults!['json'] as bool) {
      stdout.writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert([for (final p in peers) p.raw]),
      );
      return 0;
    }
    if (peers.isEmpty) {
      stdout.writeln('no peers');
      return 0;
    }
    stdout.writeln(
      table(
        const [
          'NAME',
          'IPV4',
          'IPV6',
          'ONLINE',
          'OS',
          'TAGS',
          'LAST SEEN',
          'OWNER',
        ],
        [
          for (final p in peers)
            [
              p.name,
              p.ipv4 ?? '-',
              p.ipv6 ?? '-',
              yesNo(p.online),
              p.os.isEmpty ? '-' : p.os,
              listOrDash(p.tags),
              p.online ? 'now' : relativeTime(p.lastSeen),
              status.userOf(p)?.loginName ?? '-',
            ],
        ],
      ),
    );
    return 0;
  }
}
