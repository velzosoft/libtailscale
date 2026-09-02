// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'artifact_download.dart';
import 'go_build.dart';
import 'native_manifest.dart';
import 'native_target.dart';
import 'user_config.dart';

/// Where the library came from, for logging and tests.
enum NativeLibrarySource {
  /// Copied from `prebuilt_dir`.
  prebuilt,

  /// Built with Go from `source_dir` or a pinned checkout.
  source,

  /// Downloaded from the native release and verified.
  download,
}

/// A resolved native library.
final class ResolvedLibrary {
  /// Creates the result.
  const ResolvedLibrary(this.file, this.source, {this.dependencies = const []});

  /// The library file in the hook's output directory.
  final Uri file;

  /// How it was obtained.
  final NativeLibrarySource source;

  /// Files whose change should re-run the hook.
  final List<Uri> dependencies;
}

/// Decides how to obtain `libtailscale.{dylib,so}` for a target, in this
/// order: `prebuilt_dir`, `build_from_source`, verified download.
final class NativeLibraryResolver {
  /// Creates a resolver.
  NativeLibraryResolver({
    required this.target,
    required this.config,
    required this.outputDirectory,
    required this.sharedDirectory,
    required this.log,
    this.cCompiler,
    this.packageRoot,
    GoBuilder? builder,
    ArtifactDownloader? downloader,
  }) : _builder = builder ?? GoBuilder(log: log),
       _downloader =
           downloader ??
           ArtifactDownloader(cacheDir: sharedDirectory, log: log);

  /// The platform being built.
  final NativeTarget target;

  /// User configuration.
  final HookUserConfig config;

  /// Where the final library must be placed (per-build output directory).
  final Uri outputDirectory;

  /// Cache shared across builds.
  final Uri sharedDirectory;

  /// Progress sink.
  final void Function(String message) log;

  /// Compiler toolchain from the hook input (Android/iOS).
  final CCompilerConfig? cCompiler;

  /// Package root, used to find the monorepo submodule during development.
  final Uri? packageRoot;

  final GoBuilder _builder;
  final ArtifactDownloader _downloader;

  /// The Go file added to Android builds; needs [packageRoot].
  Uri? get _androidOverlaySource =>
      packageRoot?.resolve(androidOverlayRelativePath);

  /// Resolves the library, or returns `null` when none is available and
  /// `allow_missing_native` is set. Throws [BuildError] otherwise.
  Future<ResolvedLibrary?> resolve() async {
    if (!target.isSupported) {
      throw BuildError(message: 'libtailscale: ${target.unsupportedReason}');
    }
    final prebuilt = config.prebuiltDir;
    if (prebuilt != null) return _fromPrebuilt(prebuilt);
    if (config.buildFromSource) return _fromSource();
    final url = nativeArtifactUrl(target.artifactFileName);
    if (url != null) return _fromDownload(url);
    if (config.allowMissingNative) {
      log(
        'libtailscale: no native library for ${target.artifactKey}; '
        'continuing without it because allow_missing_native is set. '
        'Calls into libtailscale will fail at runtime.',
      );
      return null;
    }
    throw BuildError(
      message:
          'libtailscale: no prebuilt library is published for '
          '${target.artifactKey} (release $nativeReleaseTag).\n'
          'Either build from source (Go >= $minimumGoVersion required):\n'
          '  hooks:\n    user_defines:\n      libtailscale:\n'
          '        build_from_source: true\n'
          'or point prebuilt_dir at a directory containing '
          '${target.libraryFileName} or ${target.artifactFileName}.',
    );
  }

  Future<ResolvedLibrary> _fromPrebuilt(Uri dir) async {
    final candidates = [
      dir.resolve(target.artifactFileName),
      dir.resolve(target.libraryFileName),
    ];
    for (final candidate in candidates) {
      final file = File.fromUri(candidate);
      if (file.existsSync()) {
        final copied = await _install(file);
        log('libtailscale: using prebuilt ${file.path}');
        return ResolvedLibrary(
          copied,
          NativeLibrarySource.prebuilt,
          dependencies: [candidate],
        );
      }
    }
    throw BuildError(
      message:
          'libtailscale: prebuilt_dir $dir contains neither '
          '${target.artifactFileName} nor ${target.libraryFileName}',
    );
  }

  Future<ResolvedLibrary> _fromSource() async {
    final go = config.goExecutable ?? 'go';
    final toolchain = config.goToolchain ?? defaultGoToolchain;
    try {
      log(
        'libtailscale: ${await _builder.goVersion(go, goToolchain: toolchain)}',
      );
      final sourceDir = await _sourceDirectory();
      final (iosSdk, macosSdk) = await _builder.sdkPathsFor(target);
      final plan = GoBuildPlan.forTarget(
        target,
        sourceDir: sourceDir,
        outputDir: outputDirectory,
        goExecutable: go,
        goToolchain: toolchain,
        cCompiler: cCompiler,
        iosSdkPath: iosSdk,
        macosSdkPath: macosSdk,
        androidOverlaySource: _androidOverlaySource,
      );
      final file = await _builder.build(plan);
      return ResolvedLibrary(
        file,
        NativeLibrarySource.source,
        dependencies: [
          sourceDir.resolve('tailscale.go'),
          sourceDir.resolve('tailscale.c'),
          sourceDir.resolve('go.mod'),
          if (target.os == OS.android && _androidOverlaySource != null)
            _androidOverlaySource!,
        ],
      );
    } on StateError catch (e) {
      throw BuildError(
        message: 'libtailscale: source build failed: ${e.message}',
      );
    } on UnsupportedError catch (e) {
      throw BuildError(message: 'libtailscale: ${e.message}');
    }
  }

  /// Builds upstream's `tstestcontrol` as `libtstestcontrol.{dylib,so}` for
  /// the hermetic integration tests. Always a source build.
  Future<ResolvedLibrary> resolveTestControl() async {
    final go = config.goExecutable ?? 'go';
    try {
      final sourceDir = await _sourceDirectory();
      final (iosSdk, macosSdk) = await _builder.sdkPathsFor(target);
      final plan = GoBuildPlan.forTarget(
        target,
        sourceDir: sourceDir.resolve('tstestcontrol/'),
        outputDir: outputDirectory.resolve('testcontrol/'),
        goExecutable: go,
        goToolchain: config.goToolchain ?? defaultGoToolchain,
        cCompiler: cCompiler,
        iosSdkPath: iosSdk,
        macosSdkPath: macosSdk,
        androidOverlaySource: _androidOverlaySource,
        libraryFileName: 'libtstestcontrol.${target.libraryExtension}',
      );
      final file = await _builder.build(plan);
      return ResolvedLibrary(
        file,
        NativeLibrarySource.source,
        dependencies: [sourceDir.resolve('tstestcontrol/tstestcontrol.go')],
      );
    } on StateError catch (e) {
      throw BuildError(
        message: 'libtailscale: tstestcontrol build failed: ${e.message}',
      );
    }
  }

  Future<Uri> _sourceDirectory() async {
    final configured = config.sourceDir;
    if (configured != null) {
      if (!File.fromUri(configured.resolve('tailscale.go')).existsSync()) {
        throw StateError('source_dir $configured has no tailscale.go');
      }
      return configured;
    }
    // Development checkout: the git submodule inside the package root.
    final root = packageRoot;
    if (root != null) {
      final submodule = root.resolve('third_party/libtailscale/');
      if (File.fromUri(submodule.resolve('tailscale.go')).existsSync()) {
        return submodule;
      }
    }
    return _builder.ensureSources(sharedDirectory);
  }

  Future<ResolvedLibrary> _fromDownload(Uri url) async {
    final expected = nativeArtifacts[target.artifactFileName]!;
    try {
      final cached = await _downloader.fetch(
        url: url,
        expectedSha256: expected,
        fileName: target.artifactFileName,
      );
      final installed = await _install(cached);
      return ResolvedLibrary(
        installed,
        NativeLibrarySource.download,
        dependencies: [cached.uri],
      );
    } on IOException catch (e) {
      throw BuildError(
        message:
            'libtailscale: download of $url failed: $e\n'
            'Offline? Use prebuilt_dir or build_from_source.',
      );
    } on StateError catch (e) {
      throw BuildError(message: 'libtailscale: ${e.message}');
    }
  }

  /// Copies [source] into the output directory under the constant file name.
  Future<Uri> _install(File source) async {
    final dir = Directory.fromUri(outputDirectory);
    await dir.create(recursive: true);
    final destination = outputDirectory.resolve(target.libraryFileName);
    await source.copy(destination.toFilePath());
    return destination;
  }
}
