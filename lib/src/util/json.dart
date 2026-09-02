// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Lenient JSON accessors for Go-encoded documents.
///
/// tailscale's JSON uses Go field names, `null` for nil slices and maps, and
/// `0001-01-01T00:00:00Z` for the zero `time.Time`. These helpers normalise
/// all of that and never throw on unexpected shapes.
library;

/// Returns [v] as a string, or `null` when absent or not a string.
String? asString(Object? v) => v is String ? v : null;

/// Returns [v] as an int (accepting doubles with integral values).
int? asInt(Object? v) {
  if (v is int) return v;
  if (v is double && v == v.truncateToDouble()) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Returns [v] as a bool, or `null`.
bool? asBool(Object? v) => v is bool ? v : null;

/// Returns [v] as a JSON object, or `null`.
Map<String, Object?>? asMap(Object? v) => v is Map<String, Object?> ? v : null;

/// Returns [v] as a list of strings (skipping non-string items), or `null`.
List<String>? asStringList(Object? v) {
  if (v is! List) return null;
  return [
    for (final e in v)
      if (e is String) e,
  ];
}

/// Returns [v] as a list of JSON objects, or `null`.
List<Map<String, Object?>>? asMapList(Object? v) {
  if (v is! List) return null;
  return [
    for (final e in v)
      if (e is Map<String, Object?>) e,
  ];
}

/// The Go zero time as serialised by `encoding/json`.
const goZeroTime = '0001-01-01T00:00:00Z';

/// Parses a Go RFC 3339 time; the zero time and unparsable values yield null.
DateTime? asTime(Object? v) {
  if (v is! String || v.isEmpty || v == goZeroTime) return null;
  if (v.startsWith('0001-01-01')) return null;
  return DateTime.tryParse(v)?.toUtc();
}
