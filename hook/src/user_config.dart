// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:hooks/hooks.dart';

/// Developer override file, relative to this package's root.
///
/// Hooks run with a filtered environment (only `PATH`, `HOME` and the temp
/// directory), so environment variables cannot configure the build. This
/// git-ignored JSON file takes the same keys as the pubspec user-defines and
/// overrides them:
///
/// ```json
/// {"build_from_source": true, "build_test_control": true}
/// ```
///
/// It is only consulted when the root package names it with the
/// `local_config` user-define. This package's own `pubspec.yaml` does so, so
/// the file applies to `dart test` and the tools in `tool/`; when libtailscale
/// is a dependency (including the examples in this repository) the file is
/// ignored and the application configures the hook in its own pubspec.
const localConfigFileName = 'hook/local_config.json';

/// How an application configures the libtailscale build hook.
///
/// Values come from the root package's `pubspec.yaml`:
///
/// ```yaml
/// hooks:
///   user_defines:
///     libtailscale:
///       build_from_source: true      # needs Go >= 1.25.5 (+ NDK / Xcode)
///       prebuilt_dir: native/libs    # air-gapped builds
///       source_dir: ../libtailscale  # Go sources for build_from_source
///       go: /usr/local/go/bin/go
///       go_toolchain: local          # default: go1.25.5+auto (see native_manifest)
///       allow_missing_native: true   # this package's tests only
///       build_test_control: true     # tests only: hermetic control server
///       local_config: hook/local_config.json  # developer override file
/// ```
///
/// While developing this package itself, the [localConfigFileName] file named
/// by `local_config` in its own pubspec overrides these.
final class HookUserConfig {
  /// Creates a configuration.
  const HookUserConfig({
    this.prebuiltDir,
    this.buildFromSource = false,
    this.allowMissingNative = false,
    this.sourceDir,
    this.goExecutable,
    this.goToolchain,
    this.buildTestControl = false,
  });

  /// Reads the configuration from the pubspec user-defines in [input] and the
  /// local override file named by the `local_config` user-define, if any.
  factory HookUserConfig.from(BuildInput input) {
    final defines = input.userDefines;
    final file = localConfigFile(input);
    final local = file == null ? null : LocalHookConfig.read(file);
    return HookUserConfig.resolve(
      value: (key) =>
          local != null && local.has(key) ? local.value(key) : defines[key],
      path: (key) =>
          local != null && local.has(key) ? local.path(key) : defines.path(key),
    );
  }

  /// Builds a configuration from two lookups: [value] returns the raw value
  /// of a key and [path] resolves a key holding a path to an absolute URI.
  ///
  /// Pure; [HookUserConfig.from] wires it to the hook input.
  factory HookUserConfig.resolve({
    required Object? Function(String key) value,
    required Uri? Function(String key) path,
  }) {
    Uri? dir(String key) {
      final uri = path(key);
      return uri == null ? null : _withTrailingSlash(uri);
    }

    final go = value('go');
    final toolchain = value('go_toolchain');
    return HookUserConfig(
      prebuiltDir: dir('prebuilt_dir'),
      buildFromSource: _truthy(value('build_from_source')),
      allowMissingNative: _truthy(value('allow_missing_native')),
      sourceDir: dir('source_dir'),
      goExecutable: go is String && go.isNotEmpty ? go : null,
      goToolchain: toolchain is String && toolchain.isNotEmpty
          ? toolchain
          : null,
      buildTestControl: _truthy(value('build_test_control')),
    );
  }

  /// The local override file named by the `local_config` user-define of the
  /// root package, or `null` when it sets none. The file need not exist.
  static File? localConfigFile(BuildInput input) {
    final uri = input.userDefines.path('local_config');
    return uri == null ? null : File.fromUri(uri);
  }

  /// Directory holding a prebuilt library for the target.
  final Uri? prebuiltDir;

  /// Build the library with the Go toolchain.
  final bool buildFromSource;

  /// Emit no libtailscale asset when none can be obtained (tests only).
  final bool allowMissingNative;

  /// Go sources of libtailscale; defaults to a pinned checkout.
  final Uri? sourceDir;

  /// Path to the `go` executable; defaults to `go` on `PATH`.
  final String? goExecutable;

  /// `GOTOOLCHAIN` for source builds; `null` means the pinned default.
  final String? goToolchain;

  /// Also build upstream's `tstestcontrol` (in-process control server, DERP
  /// and STUN) for the hermetic integration tests. Needs Go.
  final bool buildTestControl;

  static bool _truthy(Object? value) => switch (value) {
    final bool b => b,
    final String s => const {
      '1',
      'true',
      'yes',
      'on',
    }.contains(s.toLowerCase()),
    final int i => i != 0,
    _ => false,
  };

  static Uri _withTrailingSlash(Uri uri) =>
      uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');

  @override
  String toString() =>
      'HookUserConfig(prebuiltDir: $prebuiltDir, '
      'buildFromSource: $buildFromSource, allowMissingNative: $allowMissingNative, '
      'sourceDir: $sourceDir, go: $goExecutable, goToolchain: $goToolchain, '
      'buildTestControl: $buildTestControl)';
}

/// The parsed [localConfigFileName] file.
final class LocalHookConfig {
  /// Creates a config from decoded JSON [values]; relative paths resolve
  /// against [baseUri] (the directory containing the file).
  const LocalHookConfig(this.values, this.baseUri);

  /// Reads [file]; `null` when it does not exist.
  ///
  /// Throws [BuildError] when the file is not a JSON object.
  static LocalHookConfig? read(File file) {
    if (!file.existsSync()) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw BuildError(message: '${file.path} is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw BuildError(message: '${file.path} must contain a JSON object');
    }
    return LocalHookConfig(decoded, file.parent.uri);
  }

  /// Decoded key/value pairs.
  final Map<String, Object?> values;

  /// Base for relative paths.
  final Uri baseUri;

  /// Whether [key] is set (to a non-null value).
  bool has(String key) => values[key] != null;

  /// Raw value of [key].
  Object? value(String key) => values[key];

  /// [key] interpreted as a path, resolved against [baseUri].
  Uri? path(String key) {
    final raw = values[key];
    if (raw is! String || raw.isEmpty) return null;
    return baseUri.resolveUri(Uri.file(raw));
  }
}
