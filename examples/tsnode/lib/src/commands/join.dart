// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import '../format.dart';
import '../session.dart';
import 'node_command.dart';

/// Joins the tailnet and stays connected until interrupted.
final class JoinCommand extends NodeCommand {
  @override
  String get name => 'join';

  @override
  String get description =>
      'Join the tailnet, print the node details and stay online until Ctrl-C.';

  @override
  Future<int> runWithNode(NodeSession session) async {
    final node = session.node;
    final status = await node.status(includePeers: false);
    final self = status.self;
    stdout.writeln(
      keyValues({
        'hostname': self?.hostName ?? node.config.hostname,
        'magicdns': self?.magicDnsName ?? '-',
        'ipv4': node.addresses.ipv4?.address ?? '-',
        'ipv6': node.addresses.ipv6?.address ?? '-',
        'tailnet': status.currentTailnet?.name ?? '-',
        'control': node.config.effectiveControlUrl.toString(),
      }),
    );
    stderr.writeln('online; press Ctrl-C to leave');
    await NodeSession.waitForInterrupt();
    stderr.writeln('leaving');
    return 0;
  }
}
