// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import '../format.dart';
import '../session.dart';
import 'node_command.dart';

/// Prints this node's details.
final class InfoCommand extends NodeCommand {
  InfoCommand() {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Print the raw status document instead of a summary.',
    );
  }

  @override
  String get name => 'info';

  @override
  String get description => 'Show this node: names, addresses, tailnet, state.';

  @override
  Future<int> runWithNode(NodeSession session) async {
    final node = session.node;
    final status = await node.status(includePeers: false);
    if (argResults!['json'] as bool) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(status.raw));
      return 0;
    }
    final self = status.self;
    stdout.writeln(
      keyValues({
        'hostname': self?.hostName ?? node.config.hostname,
        'magicdns': self?.magicDnsName ?? '-',
        'ipv4': node.addresses.ipv4?.address ?? '-',
        'ipv6': node.addresses.ipv6?.address ?? '-',
        'tailnet': status.currentTailnet?.name ?? '-',
        'dns suffix': status.magicDnsSuffix.isEmpty
            ? '-'
            : status.magicDnsSuffix,
        'state': status.backendStateName,
        'control': node.config.effectiveControlUrl.toString(),
        'node id': self == null || self.id.isEmpty ? '-' : self.id,
        'os': self?.os ?? '-',
        'tags': listOrDash(self?.tags ?? const []),
        'key expiry': self?.keyExpiry?.toIso8601String() ?? 'never',
        'version': status.version,
        'certificates': yesNo(status.supportsCertificates),
        'health': status.health.isEmpty ? 'ok' : status.health.join('; '),
      }),
    );
    return 0;
  }
}
