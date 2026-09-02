// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter/material.dart';

/// A labelled, selectable value line.
class KeyValueRow extends StatelessWidget {
  /// Creates a row.
  const KeyValueRow(
    this.label,
    this.value, {
    super.key,
    this.monospace = false,
  });

  /// Left column.
  final String label;

  /// Right column; an empty value renders as a dash.
  final String value;

  /// Use a monospace font for the value (ids, addresses).
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 136,
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: monospace
                  ? text.bodyMedium?.copyWith(fontFamily: 'monospace')
                  : text.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small coloured heading between groups of rows.
class SectionHeader extends StatelessWidget {
  /// Creates a header.
  const SectionHeader(this.title, {super.key});

  /// Heading text.
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// Centered hint for screens that have nothing to show yet.
class EmptyPlaceholder extends StatelessWidget {
  /// Creates a placeholder.
  const EmptyPlaceholder({super.key, required this.icon, required this.text});

  /// Large icon.
  final IconData icon;

  /// Explanation.
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
