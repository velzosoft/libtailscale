// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Builds a native libtailscale library outside the hook, for the release
/// pipeline and for local experiments.
///
/// ```sh
/// dart run tool/build_native.dart --os macos --arch arm64 --out build/native
/// dart run tool/build_native.dart --os ios --arch arm64 --ios-sdk iphonesimulator --out build/native
/// dart run tool/build_native.dart --os android --arch arm64 --cc $NDK/.../aarch64-linux-android35-clang --out build/native
/// ```
///
/// Prints `<sha256>  <artifact file name>` (the `sha256sum` format) so the
/// release workflow can concatenate the lines into `SHA256SUMS` and
/// `tool/update_manifest.dart` can pin them in `lib/src/hook/native_manifest.dart`.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';

import 'package:libtailscale/src/hook/artifact_download.dart';
import 'package:libtailscale/src/hook/go_build.dart';
import 'package:libtailscale/src/hook/native_manifest.dart';
import 'package:libtailscale/src/hook/native_target.dart';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final target = NativeTarget(
    os: options.os,
    architecture: options.arch,
    iosSdk: options.iosSdk,
    androidNdkApi: options.androidApi,
  );
  final builder = GoBuilder(log: stderr.writeln);
  final outDir = Directory(options.out).absolute.uri.normalizePath();
  final sourceDir = options.source != null
      ? Directory(options.source!).absolute.uri.normalizePath()
      : await builder.ensureSources(outDir.resolve('cache/'));
  final sdkPaths = await builder.sdkPathsFor(target);
  final plan = GoBuildPlan.forTarget(
    target,
    sourceDir: _withSlash(sourceDir),
    outputDir: _withSlash(outDir),
    goExecutable: options.go,
    goToolchain: options.goToolchain,
    cCompiler: options.cc == null
        ? null
        : CCompilerConfig(
            compiler: File(options.cc!).absolute.uri,
            linker: File(options.cc!).absolute.uri,
            archiver: File(options.cc!).absolute.uri,
          ),
    iosSdkPath: sdkPaths.$1,
    macosSdkPath: sdkPaths.$2,
    androidOverlaySource: Platform.script.resolve(
      '../$androidOverlayRelativePath',
    ),
  );
  final built = await builder.build(plan);
  final artifact = File.fromUri(outDir.resolve(target.artifactFileName));
  await File.fromUri(built).copy(artifact.path);
  final digest = await sha256OfFile(artifact);
  stdout.writeln('$digest  ${target.artifactFileName}');
}

Uri _withSlash(Uri dir) =>
    dir.path.endsWith('/') ? dir : dir.replace(path: '${dir.path}/');

final class _Options {
  _Options({
    required this.os,
    required this.arch,
    required this.out,
    this.iosSdk,
    this.androidApi,
    this.source,
    this.cc,
    this.go = 'go',
    this.goToolchain = defaultGoToolchain,
  });

  final OS os;
  final Architecture arch;
  final String out;
  final IOSSdk? iosSdk;
  final int? androidApi;
  final String? source;
  final String? cc;
  final String go;
  final String goToolchain;
}

_Options _parse(List<String> args) {
  String? os, arch, out, iosSdk, androidApi, source, cc;
  var go = 'go';
  var goToolchain = defaultGoToolchain;
  for (var i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) _usage('missing value for ${args[i]}');
      return args[++i];
    }

    switch (args[i]) {
      case '--os':
        os = next();
      case '--arch':
        arch = next();
      case '--out':
        out = next();
      case '--ios-sdk':
        iosSdk = next();
      case '--android-api':
        androidApi = next();
      case '--source':
        source = next();
      case '--cc':
        cc = next();
      case '--go':
        go = next();
      case '--go-toolchain':
        goToolchain = next();
      case '--help' || '-h':
        _usage(null);
      default:
        _usage('unknown argument ${args[i]}');
    }
  }
  if (os == null || arch == null || out == null) {
    _usage('--os, --arch and --out are required');
  }
  return _Options(
    os: OS.fromString(os),
    arch: Architecture.fromString(arch),
    out: out,
    iosSdk: iosSdk == null
        ? (os == 'ios' ? IOSSdk.iPhoneOS : null)
        : IOSSdk.fromString(iosSdk),
    androidApi: androidApi == null ? null : int.parse(androidApi),
    source: source,
    cc: cc,
    go: go,
    goToolchain: goToolchain,
  );
}

Never _usage(String? error) {
  if (error != null) stderr.writeln('error: $error\n');
  stderr.writeln(
    'usage: dart run tool/build_native.dart --os <macos|linux|ios|android> '
    '--arch <arm64|x64|arm> --out <dir> [--ios-sdk iphoneos|iphonesimulator] '
    '[--android-api 35] [--source <libtailscale checkout>] [--cc <clang>] '
    '[--go <go>] [--go-toolchain go1.25.5+auto|local]',
  );
  exit(error == null ? 0 : 64);
}
