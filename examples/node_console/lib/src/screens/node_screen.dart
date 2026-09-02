// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter/material.dart';
import 'package:libtailscale/libtailscale.dart';

import '../node_controller.dart';
import '../widgets/key_value_list.dart';

/// This node's details and the peer list, refreshed every few seconds from
/// `node.status()` and `node.addresses`.
class NodeScreen extends StatelessWidget {
  /// Creates the screen.
  const NodeScreen({super.key, required this.controller});

  /// Source of the status.
  final NodeController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      if (c.phase != ConsolePhase.connected) {
        return EmptyPlaceholder(
          icon: Icons.dns_outlined,
          text: c.phase == ConsolePhase.connecting
              ? 'Waiting for the node to run…'
              : 'Connect first. Node details and peers appear here.',
        );
      }
      final status = c.status;
      if (status == null) {
        return Center(
          child: c.statusError == null
              ? const CircularProgressIndicator()
              : Text('Status unavailable: ${c.statusError}'),
        );
      }
      final self = status.self;
      final peers = [...status.peers]
        ..sort((a, b) {
          if (a.online != b.online) return a.online ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      final config = c.node?.config;
      return RefreshIndicator(
        onRefresh: c.refreshStatus,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const SectionHeader('This node'),
            KeyValueRow('Hostname', self?.hostName ?? c.form.hostname),
            KeyValueRow('MagicDNS name', self?.magicDnsName ?? ''),
            KeyValueRow(
              'IPv4',
              c.addresses.ipv4?.address ?? '',
              monospace: true,
            ),
            KeyValueRow(
              'IPv6',
              c.addresses.ipv6?.address ?? '',
              monospace: true,
            ),
            KeyValueRow('Tailnet', status.currentTailnet?.name ?? ''),
            KeyValueRow('DNS suffix', status.magicDnsSuffix),
            KeyValueRow('Backend state', status.backendStateName),
            KeyValueRow(
              'Control URL',
              config?.effectiveControlUrl.toString() ?? '',
            ),
            KeyValueRow('Node ID', self?.id ?? '', monospace: true),
            KeyValueRow('OS', self?.os ?? ''),
            KeyValueRow('Key expiry', _formatDate(self?.keyExpiry)),
            KeyValueRow('Client version', status.version),
            KeyValueRow(
              'Health',
              status.health.isEmpty ? 'ok' : status.health.join('\n'),
            ),
            KeyValueRow(
              'Certificates',
              status.certDomains.isEmpty
                  ? 'not offered by this control server'
                  : status.certDomains.join(', '),
            ),
            KeyValueRow('Updated', _formatTime(c.statusAt)),
            if (c.statusError case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Last refresh failed: $error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            SectionHeader('Peers (${peers.length})'),
            if (peers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No peers yet.'),
              ),
            for (final peer in peers)
              _PeerTile(peer: peer, owner: status.userOf(peer)),
          ],
        ),
      );
    },
  );
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.owner});

  final PeerStatus peer;
  final UserProfile? owner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = <String>[
      peer.tailscaleIps.join(' · '),
      [
        peer.os,
        if (peer.tags.isNotEmpty) peer.tags.join(' '),
        if (owner != null && !owner!.isTaggedDevices) owner!.loginName,
      ].where((s) => s.isNotEmpty).join(' · '),
      peer.online
          ? (peer.curAddr.isNotEmpty
                ? 'direct ${peer.curAddr}'
                : peer.relay.isNotEmpty
                ? 'via DERP ${peer.relay}'
                : 'online')
          : 'last seen ${_formatAgo(peer.lastSeen)}',
      if (peer.expired) 'key expired',
    ].where((s) => s.isNotEmpty).toList();
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.circle,
        size: 12,
        color: peer.online ? Colors.green : scheme.outlineVariant,
      ),
      title: Text(peer.name),
      subtitle: SelectableText(details.join('\n')),
      isThreeLine: details.length > 2,
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String _formatTime(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

String _formatDate(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}';
}

String _formatAgo(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
