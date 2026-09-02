// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:test/test.dart';

import '../../hook/src/native_manifest.dart';
import '../../hook/src/native_target.dart';
import '../../tool/src/manifest_update.dart';

String _digest(int seed) => seed.toRadixString(16).padLeft(64, '0');

void main() {
  group('parseSha256Sums', () {
    test('accepts sha256sum output, comments and binary markers', () {
      final sums = parseSha256Sums('''
# generated
${_digest(1)}  libtailscale-macos-arm64.dylib
${_digest(2).toUpperCase()} *libtailscale-linux-x64.so

''');
      expect(sums, {
        'libtailscale-macos-arm64.dylib': _digest(1),
        'libtailscale-linux-x64.so': _digest(2),
      });
    });

    test('rejects malformed lines and duplicates', () {
      expect(
        () => parseSha256Sums('abc  file'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseSha256Sums('${_digest(1)}  a\n${_digest(2)}  a'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('release targets are the ten shipped libraries, all supported', () {
    expect(releaseArtifactNames, [
      'libtailscale-macos-arm64.dylib',
      'libtailscale-macos-x64.dylib',
      'libtailscale-ios-arm64-iphoneos.dylib',
      'libtailscale-ios-arm64-iphonesimulator.dylib',
      'libtailscale-ios-x64-iphonesimulator.dylib',
      'libtailscale-linux-x64.so',
      'libtailscale-linux-arm64.so',
      'libtailscale-android-arm64.so',
      'libtailscale-android-x64.so',
      'libtailscale-android-arm.so',
    ]);
    for (final target in NativeTarget.releaseTargets) {
      expect(target.isSupported, isTrue, reason: '$target');
    }
  });

  test('the release workflow matrix matches the release targets', () {
    final workflow = File(
      '.github/workflows/native-release.yml',
    ).readAsStringSync();
    final matrixNames = RegExp(
      r'- \{ name: ([a-z0-9-]+),',
    ).allMatches(workflow).map((m) => m.group(1)!).toList();
    expect(matrixNames, [
      for (final target in NativeTarget.releaseTargets)
        target.artifactKey.replaceFirst('libtailscale-', ''),
    ]);
  });

  test('checkArtifactSet reports missing and unexpected names', () {
    final result = checkArtifactSet({
      'libtailscale-macos-arm64.dylib': _digest(1),
      'libtailscale-windows-x64.dll': _digest(2),
    });
    expect(result.missing, hasLength(9));
    expect(result.missing, isNot(contains('libtailscale-macos-arm64.dylib')));
    expect(result.unexpected, ['libtailscale-windows-x64.dll']);
  });

  group('updateManifestSource', () {
    final source = File('hook/src/native_manifest.dart').readAsStringSync();

    test('reads the committed manifest', () {
      final current = readManifest(source);
      expect(current.tag, nativeReleaseTag);
      expect(current.artifacts, nativeArtifacts);
    });

    test('rewrites tag and map in release order and round-trips', () {
      final artifacts = {
        for (final (i, name) in releaseArtifactNames.indexed) name: _digest(i),
        'libtailscale-extra.so': _digest(99),
      };
      final updated = updateManifestSource(
        source,
        tag: 'native-v9.9.9',
        artifacts: artifacts,
      );
      final reread = readManifest(updated);
      expect(reread.tag, 'native-v9.9.9');
      expect(reread.artifacts, artifacts);
      expect(reread.artifacts.keys.toList(), [
        ...releaseArtifactNames,
        'libtailscale-extra.so',
      ], reason: 'release order, extras last');
      // Everything else in the file is untouched.
      expect(updated, contains("const upstreamCommit = '$upstreamCommit';"));
      expect(updated, contains('Uri? nativeArtifactUrl('));
      // Applying the same update again is a no-op.
      expect(
        updateManifestSource(
          updated,
          tag: 'native-v9.9.9',
          artifacts: artifacts,
        ),
        updated,
      );
    });

    test('an empty set restores the empty literal', () {
      final updated = updateManifestSource(
        source,
        tag: 'native-v0.0.1',
        artifacts: const {},
      );
      expect(updated, contains('const nativeArtifacts = <String, String>{};'));
    });

    test('rejects bad digests, names and tags', () {
      expect(
        () => updateManifestSource(
          source,
          tag: 'native-v1.0.0',
          artifacts: {'a': 'xyz'},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => updateManifestSource(
          source,
          tag: 'native-v1.0.0',
          artifacts: {"a'b": _digest(1)},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => updateManifestSource(source, tag: "x'", artifacts: const {}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => updateManifestSource(
          'void main() {}',
          tag: 'native-v1.0.0',
          artifacts: const {},
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
