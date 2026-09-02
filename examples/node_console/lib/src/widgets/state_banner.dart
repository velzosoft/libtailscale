// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../node_controller.dart';

/// Shows the lifecycle phase, backend state, health, errors and, for
/// interactive logins, the URL to approve the node with (as copyable text;
/// the app never opens a browser on its own).
class StateBanner extends StatelessWidget {
  /// Creates the banner.
  const StateBanner({super.key, required this.controller});

  /// Source of everything shown.
  final NodeController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = controller;
    final (
      Color background,
      Color foreground,
      String title,
    ) = switch (c.phase) {
      ConsolePhase.idle when c.error != null => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        'Not connected',
      ),
      ConsolePhase.idle => (
        scheme.surfaceContainerHighest,
        scheme.onSurface,
        'Disconnected',
      ),
      ConsolePhase.connecting => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        'Connecting · ${c.backendState?.wireName ?? 'starting'}',
      ),
      ConsolePhase.connected => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        'Running · ${c.addresses.ipv4?.address ?? c.addresses.ipv6?.address ?? ''}',
      ),
    };
    final authUrl = c.authUrl;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle(
        style: text.bodyMedium!.copyWith(color: foreground),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (c.phase == ConsolePhase.connecting)
                  const Padding(
                    padding: EdgeInsets.only(right: 10),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Expanded(
                  child: Text(
                    title,
                    style: text.titleMedium?.copyWith(color: foreground),
                  ),
                ),
              ],
            ),
            if (c.error case final error?) ...[
              const SizedBox(height: 6),
              SelectableText(error, style: TextStyle(color: scheme.error)),
            ],
            if (c.warning case final warning?) ...[
              const SizedBox(height: 6),
              Text(warning),
            ],
            for (final problem in c.health) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 6, top: 2),
                    child: Icon(Icons.warning_amber, size: 16),
                  ),
                  Expanded(child: Text(problem)),
                ],
              ),
            ],
            if (authUrl != null && c.phase == ConsolePhase.connecting) ...[
              const SizedBox(height: 10),
              const Text('Approve this node at:'),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      authUrl,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy URL',
                    icon: const Icon(Icons.copy),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: authUrl));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Login URL copied')),
                        );
                      }
                    },
                  ),
                ],
              ),
              const Text(
                'Headscale: headscale auth register --auth-id <id from the URL> '
                '--user <user>',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
