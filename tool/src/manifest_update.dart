// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Pure helpers behind `tool/update_manifest.dart`: parse a `SHA256SUMS`
/// file and rewrite the generated constants in `hook/src/native_manifest.dart`.
library;

import '../../hook/src/native_target.dart';

final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _tagPattern = RegExp(r"const nativeReleaseTag = '([^']*)';");
final _mapPattern = RegExp(
  r'const nativeArtifacts = <String, String>\{(.*?)\};',
  dotAll: true,
);
final _entryPattern = RegExp(r"'([^']+)':\s*'([0-9a-f]{64})'");

/// Parses `sha256sum` output: one `<hex>  <name>` line per artifact (a `*`
/// binary marker before the name is accepted). Blank lines and `#` comments
/// are skipped. Throws [FormatException] on malformed lines or duplicates.
Map<String, String> parseSha256Sums(String text) {
  final result = <String, String>{};
  for (final (index, raw) in text.split('\n').indexed) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(\S+)$').firstMatch(line);
    if (match == null) {
      throw FormatException('line ${index + 1} is not "<sha256>  <file>"', raw);
    }
    final name = match.group(2)!;
    if (result.containsKey(name)) {
      throw FormatException('line ${index + 1}: duplicate entry for $name');
    }
    result[name] = match.group(1)!.toLowerCase();
  }
  return result;
}

/// The artifact file names a release must contain, in manifest order.
List<String> get releaseArtifactNames => [
  for (final target in NativeTarget.releaseTargets) target.artifactFileName,
];

/// Compares [artifacts] with [releaseArtifactNames].
({List<String> missing, List<String> unexpected}) checkArtifactSet(
  Map<String, String> artifacts,
) {
  final expected = releaseArtifactNames;
  return (
    missing: [
      for (final name in expected)
        if (!artifacts.containsKey(name)) name,
    ],
    unexpected: [
      for (final name in artifacts.keys)
        if (!expected.contains(name)) name,
    ]..sort(),
  );
}

/// The tag and artifact map currently pinned in the manifest [source].
({String tag, Map<String, String> artifacts}) readManifest(String source) {
  final tag = _tagPattern.firstMatch(source);
  final map = _mapPattern.firstMatch(source);
  if (tag == null || map == null) {
    throw const FormatException(
      'manifest has no nativeReleaseTag / nativeArtifacts constants',
    );
  }
  return (
    tag: tag.group(1)!,
    artifacts: {
      for (final entry in _entryPattern.allMatches(map.group(1)!))
        entry.group(1)!: entry.group(2)!,
    },
  );
}

/// Returns [source] with `nativeReleaseTag` set to [tag] and
/// `nativeArtifacts` replaced by [artifacts] (release targets first, in
/// [releaseArtifactNames] order, then any extra names alphabetically).
///
/// Values must be lowercase 64-digit hex. The result is valid Dart but not
/// necessarily formatted; run `dart format` afterwards.
String updateManifestSource(
  String source, {
  required String tag,
  required Map<String, String> artifacts,
}) {
  for (final entry in artifacts.entries) {
    if (!_hex64.hasMatch(entry.value)) {
      throw FormatException(
        '${entry.key}: not a SHA-256 hex digest',
        entry.value,
      );
    }
    if (entry.key.contains("'") || entry.key.contains(r'$')) {
      throw FormatException('unsafe artifact name', entry.key);
    }
  }
  if (tag.contains("'") || tag.contains(r'$') || tag.trim().isEmpty) {
    throw FormatException('unsafe release tag', tag);
  }
  readManifest(source); // validates the structure
  final ordered = [
    for (final name in releaseArtifactNames)
      if (artifacts.containsKey(name)) name,
    ...checkArtifactSet(artifacts).unexpected,
  ];
  final body = ordered.isEmpty
      ? '{}'
      : '{\n${ordered.map((n) => "  '$n':\n      '${artifacts[n]}',").join('\n')}\n}';
  return source
      .replaceFirst(_tagPattern, "const nativeReleaseTag = '$tag';")
      .replaceFirst(
        _mapPattern,
        'const nativeArtifacts = <String, String>$body;',
      );
}
