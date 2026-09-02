// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Plain-text formatting helpers for command output.
library;

/// Renders [rows] under [headers] as an aligned, space-separated table.
String table(List<String> headers, List<List<String>> rows) {
  final widths = List<int>.generate(headers.length, (i) => headers[i].length);
  for (final row in rows) {
    for (var i = 0; i < headers.length && i < row.length; i++) {
      if (row[i].length > widths[i]) widths[i] = row[i].length;
    }
  }
  String line(List<String> cells) => [
    for (var i = 0; i < headers.length; i++)
      (i < cells.length ? cells[i] : '').padRight(widths[i]),
  ].join('  ').trimRight();
  return [line(headers), for (final row in rows) line(row)].join('\n');
}

/// Renders `key: value` lines with aligned values.
String keyValues(Map<String, String> entries) {
  final width = entries.keys.fold<int>(
    0,
    (w, k) => k.length > w ? k.length : w,
  );
  return entries.entries
      .map((e) => '${e.key.padRight(width)}  ${e.value}')
      .join('\n');
}

/// `5m ago`, `2h ago`, `3d ago`; `-` for `null`.
String relativeTime(DateTime? time, {DateTime? now}) {
  if (time == null) return '-';
  final delta = (now ?? DateTime.now().toUtc()).difference(time.toUtc());
  if (delta.isNegative) return 'in the future';
  if (delta.inSeconds < 60) return '${delta.inSeconds}s ago';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 48) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}

/// `yes` / `no`.
String yesNo(bool value) => value ? 'yes' : 'no';

/// Joins [items] with `, `, or `-` when empty.
String listOrDash(Iterable<String> items) =>
    items.isEmpty ? '-' : items.join(', ');
