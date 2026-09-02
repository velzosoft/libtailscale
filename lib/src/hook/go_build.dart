// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';

import 'native_manifest.dart';
import 'native_target.dart';

/// Go file the hook adds to the upstream package for Android builds through
/// `go build -overlay`, relative to this package's root. It registers a
/// getifaddrs(3)-based interface getter with netmon because Android 11+ denies
/// the netlink call Go's `net.Interfaces()` relies on.
const androidOverlayRelativePath = 'lib/src/hook/android_interfaces.go';

/// File name the overlay gives that file inside the upstream package.
const androidOverlayFileName = 'zz_libtailscale_dart_android_interfaces.go';

/// A helper file a plan needs on disk before its steps run.
typedef PlanFile = ({Uri path, String contents, bool executable});

/// One external process invocation of a [GoBuildPlan].
final class ProcessStep {
  /// Creates a step.
  const ProcessStep({
    required this.description,
    required this.executable,
    required this.arguments,
    this.environment = const {},
    this.workingDirectory,
  });

  /// Human-readable purpose.
  final String description;

  /// Program to run.
  final String executable;

  /// Arguments.
  final List<String> arguments;

  /// Extra environment variables (merged over the parent environment).
  final Map<String, String> environment;

  /// Working directory, if not the current one.
  final String? workingDirectory;

  @override
  String toString() => '$description: $executable ${arguments.join(' ')}';
}

/// The commands that turn the libtailscale Go sources into a dynamic library
/// for one [NativeTarget].
///
/// Building the plan is pure (and unit-tested); [GoBuilder] executes it.
final class GoBuildPlan {
  const GoBuildPlan._({
    required this.target,
    required this.steps,
    required this.outputFile,
    this.extraFiles = const [],
  });

  /// Creates the plan.
  ///
  /// [sourceDir] holds the upstream checkout, [outputDir] receives
  /// `libtailscale.{dylib,so}`, and [cCompiler] (from the hook input) points
  /// at the NDK compiler for Android. [iosSdkPath] is the result of
  /// `xcrun --sdk <sdk> --show-sdk-path` (iOS only, required there).
  /// [macosSdkPath] is the same for the `macosx` SDK; when given, the macOS
  /// build passes it as `-isysroot`. That is necessary when the hook runs
  /// inside an Xcode build phase, where `PATH` selects the toolchain's clang
  /// directly and the hook's filtered environment has no `SDKROOT`.
  /// [androidOverlaySource] is the [androidOverlayRelativePath] file, required
  /// for Android.
  factory GoBuildPlan.forTarget(
    NativeTarget target, {
    required Uri sourceDir,
    required Uri outputDir,
    String goExecutable = 'go',
    String goToolchain = defaultGoToolchain,
    CCompilerConfig? cCompiler,
    String? iosSdkPath,
    String? macosSdkPath,
    Uri? androidOverlaySource,
    String? libraryFileName,
  }) {
    if (!target.isSupported) {
      throw UnsupportedError(target.unsupportedReason);
    }
    final src = sourceDir.toFilePath();
    final libName = libraryFileName ?? target.libraryFileName;
    final baseName = libName.substring(0, libName.indexOf('.'));
    final out = outputDir.resolve(libName).toFilePath();
    const common = ['build', '-trimpath', '-buildvcs=false'];
    final env = <String, String>{
      'CGO_ENABLED': '1',
      'GOOS': target.goos,
      'GOARCH': target.goarch,
      // Never rewrite the (vendored) go.mod; upstream's module files are
      // complete, they only lack a `go mod tidy` that -mod=mod would apply.
      'GOFLAGS': '-mod=readonly',
      'GOTOOLCHAIN': goToolchain,
    };

    switch (target.os) {
      case OS.macOS:
        final min = '-mmacos-version-min=${target.effectiveMacosVersion}.0';
        final sysroot = macosSdkPath == null ? '' : ' -isysroot $macosSdkPath';
        // Dart and Flutter rewrite the dylib's install name to an absolute
        // path at bundling time; Go's default link leaves no room for that.
        const headerPad = '-Wl,-headerpad_max_install_names';
        return GoBuildPlan._(
          target: target,
          outputFile: Uri.file(out),
          steps: [
            ProcessStep(
              description: 'go build (c-shared, macOS ${target.goarch})',
              executable: goExecutable,
              arguments: [
                ...common,
                '-ldflags',
                '-s -w',
                '-buildmode=c-shared',
                '-o',
                out,
                '.',
              ],
              environment: {
                ...env,
                'MACOSX_DEPLOYMENT_TARGET': '${target.effectiveMacosVersion}.0',
                'SDKROOT': ?macosSdkPath,
                'CGO_CFLAGS': '$min$sysroot',
                'CGO_LDFLAGS': '$min$sysroot $headerPad',
              },
              workingDirectory: src,
            ),
          ],
        );

      case OS.linux:
        final cc = cCompiler?.compiler.toFilePath();
        return GoBuildPlan._(
          target: target,
          outputFile: Uri.file(out),
          steps: [
            ProcessStep(
              description: 'go build (c-shared, Linux ${target.goarch})',
              executable: goExecutable,
              arguments: [
                ...common,
                '-ldflags',
                '-s -w',
                '-buildmode=c-shared',
                '-o',
                out,
                '.',
              ],
              environment: {...env, 'CC': ?cc},
              workingDirectory: src,
            ),
          ],
        );

      case OS.android:
        final cc = cCompiler?.compiler.toFilePath();
        if (cc == null) {
          throw StateError(
            'Android builds need the NDK compiler; the hook input did not '
            'provide one (input.config.code.cCompiler)',
          );
        }
        // Flutter passes the NDK's generic `clang`, which targets the host
        // unless told otherwise; the per-API wrapper scripts (`aarch64-linux-
        // android35-clang`) merely add this flag. Passing it is harmless when
        // [cc] already is such a wrapper.
        final api = target.effectiveAndroidApi;
        final triple = switch (target.architecture) {
          Architecture.arm64 => 'aarch64-linux-android',
          Architecture.x64 => 'x86_64-linux-android',
          Architecture.arm => 'armv7a-linux-androideabi',
          Architecture.ia32 => 'i686-linux-android',
          _ => throw UnsupportedError(target.unsupportedReason),
        };
        final targetFlag = '--target=$triple$api';
        final overlaySource = androidOverlaySource;
        if (overlaySource == null) {
          throw StateError(
            'Android builds need $androidOverlayRelativePath from this '
            'package (androidOverlaySource)',
          );
        }
        // Compile the getter as part of the upstream package without touching
        // its checkout: -overlay maps a virtual file in the package directory
        // to the file shipped in this package.
        final overlayFile = outputDir.resolve('overlay-android.json');
        final overlayJson = jsonEncode({
          'Replace': {
            sourceDir.resolve(androidOverlayFileName).toFilePath():
                overlaySource.toFilePath(),
          },
        });
        return GoBuildPlan._(
          target: target,
          outputFile: Uri.file(out),
          extraFiles: [
            (path: overlayFile, contents: overlayJson, executable: false),
          ],
          steps: [
            ProcessStep(
              description:
                  'go build (c-shared, Android ${target.goarch}, '
                  'API $api, CC=$cc)',
              executable: goExecutable,
              arguments: [
                ...common,
                '-overlay',
                overlayFile.toFilePath(),
                '-ldflags',
                '-s -w',
                '-buildmode=c-shared',
                '-o',
                out,
                '.',
              ],
              environment: {
                ...env,
                'CC': cc,
                // Android requires ARMv7; Go's cross-compile default agrees,
                // but say so explicitly.
                if (target.architecture == Architecture.arm) 'GOARM': '7',
                'CGO_CFLAGS': targetFlag,
                // Google Play requires 16 KB page alignment; the soname keeps
                // dlopen happy inside the APK.
                'CGO_LDFLAGS':
                    '$targetFlag -Wl,-z,max-page-size=16384 '
                    '-Wl,-soname,$libName',
              },
              workingDirectory: src,
            ),
          ],
        );

      case OS.iOS:
        // Go has no c-shared mode for GOOS=ios: build a c-archive with a clang
        // wrapper that pins SDK/arch/min-version, then link a dylib by hand.
        final sdkPath = iosSdkPath;
        if (sdkPath == null) {
          throw StateError(
            'iOS builds need the SDK path (xcrun --show-sdk-path)',
          );
        }
        final simulator = target.iosSdk == IOSSdk.iPhoneSimulator;
        final sdkName = simulator ? 'iphonesimulator' : 'iphoneos';
        final clangArch = target.architecture == Architecture.x64
            ? 'x86_64'
            : 'arm64';
        final minFlag = simulator
            ? '-mios-simulator-version-min=${target.effectiveIosVersion}.0'
            : '-miphoneos-version-min=${target.effectiveIosVersion}.0';
        final wrapper = outputDir.resolve('clangwrap-$sdkName-$clangArch.sh');
        final archive = outputDir.resolve('$baseName-$sdkName-$clangArch.a');
        final wrapperScript =
            '#!/bin/sh\n'
            '# Generated by libtailscale hook: clang for Go cgo on iOS.\n'
            'exec "\$(xcrun --sdk $sdkName --find clang)" '
            '-arch $clangArch -isysroot "$sdkPath" $minFlag "\$@"\n';
        return GoBuildPlan._(
          target: target,
          outputFile: Uri.file(out),
          extraFiles: [
            (path: wrapper, contents: wrapperScript, executable: true),
          ],
          steps: [
            ProcessStep(
              description: 'go build (c-archive, iOS $sdkName $clangArch)',
              executable: goExecutable,
              arguments: [
                ...common,
                '-tags',
                'ios',
                '-ldflags',
                '-w',
                '-buildmode=c-archive',
                '-o',
                archive.toFilePath(),
                '.',
              ],
              environment: {...env, 'CC': wrapper.toFilePath()},
              workingDirectory: src,
            ),
            ProcessStep(
              description: 'clang -dynamiclib (iOS $sdkName $clangArch)',
              executable: 'xcrun',
              arguments: [
                '--sdk',
                sdkName,
                'clang',
                '-dynamiclib',
                '-arch',
                clangArch,
                '-isysroot',
                sdkPath,
                minFlag,
                '-Wl,-headerpad_max_install_names',
                '-Wl,-all_load',
                archive.toFilePath(),
                '-framework',
                'CoreFoundation',
                '-framework',
                'Security',
                '-lresolv',
                '-install_name',
                '@rpath/$baseName.framework/$baseName',
                '-o',
                out,
              ],
            ),
          ],
        );

      default:
        throw UnsupportedError(target.unsupportedReason);
    }
  }

  /// The target.
  final NativeTarget target;

  /// Steps to run in order.
  final List<ProcessStep> steps;

  /// The produced library.
  final Uri outputFile;

  /// Helper files to write before running the steps (iOS clang wrapper,
  /// Android overlay).
  final List<PlanFile> extraFiles;
}

/// Runs [GoBuildPlan]s and prepares their inputs (sources, SDK paths).
final class GoBuilder {
  /// Creates a builder that reports progress through [log].
  const GoBuilder({required this.log});

  /// Progress sink.
  final void Function(String message) log;

  /// Verifies that `go` is available and reports the version that
  /// [goToolchain] selects (downloading it if needed).
  Future<String> goVersion(
    String goExecutable, {
    String goToolchain = defaultGoToolchain,
  }) async {
    final result = await _run(
      goExecutable,
      ['version'],
      environment: {'GOTOOLCHAIN': goToolchain},
    );
    if (result.exitCode != 0) {
      throw StateError(
        'cannot run `$goExecutable version` (exit ${result.exitCode}): '
        '${result.stderr}\nInstall Go >= $minimumGoVersion or set the `go` '
        'user-define to its path.',
      );
    }
    return (result.stdout as String).trim();
  }

  /// Ensures a checkout of [upstreamRepository] at [upstreamCommit] exists in
  /// [cacheDir] and returns its directory.
  Future<Uri> ensureSources(Uri cacheDir) async {
    final dir = Directory.fromUri(
      cacheDir.resolve('libtailscale-src-$upstreamCommit/'),
    );
    final marker = File.fromUri(dir.uri.resolve('.libtailscale-hook-ok'));
    if (marker.existsSync()) return dir.uri;
    if (dir.existsSync()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    log('cloning $upstreamRepository @ $upstreamCommit');
    await _runOrThrow('git', ['init', '-q'], workingDirectory: dir.path);
    await _runOrThrow('git', [
      'remote',
      'add',
      'origin',
      upstreamRepository,
    ], workingDirectory: dir.path);
    await _runOrThrow('git', [
      'fetch',
      '-q',
      '--depth',
      '1',
      'origin',
      upstreamCommit,
    ], workingDirectory: dir.path);
    await _runOrThrow('git', [
      'checkout',
      '-q',
      'FETCH_HEAD',
    ], workingDirectory: dir.path);
    await marker.writeAsString('ok\n');
    return dir.uri;
  }

  /// `xcrun --sdk <sdk> --show-sdk-path` for an iOS SDK.
  Future<String> iosSdkPath(IOSSdk sdk) => appleSdkPath(sdk.type);

  /// `xcrun --sdk <sdkName> --show-sdk-path` (`macosx`, `iphoneos`, ...).
  Future<String> appleSdkPath(String sdkName) async {
    final result = await _runOrThrow('xcrun', [
      '--sdk',
      sdkName,
      '--show-sdk-path',
    ]);
    return (result.stdout as String).trim();
  }

  /// SDK paths a plan for [target] needs: `(iosSdkPath, macosSdkPath)`.
  ///
  /// Only queried on the Apple targets; anything else gets `(null, null)`.
  Future<(String?, String?)> sdkPathsFor(NativeTarget target) async =>
      switch (target.os) {
        OS.iOS => (await iosSdkPath(target.iosSdk!), null),
        OS.macOS => (null, await appleSdkPath('macosx')),
        _ => (null, null),
      };

  /// Executes [plan]; returns the produced library.
  Future<Uri> build(GoBuildPlan plan) async {
    final outputDir = Directory.fromUri(plan.outputFile.resolve('.'));
    await outputDir.create(recursive: true);
    for (final extra in plan.extraFiles) {
      final file = File.fromUri(extra.path);
      await file.writeAsString(extra.contents);
      if (extra.executable) await _runOrThrow('chmod', ['+x', file.path]);
    }
    for (final step in plan.steps) {
      log(step.toString());
      await _runOrThrow(
        step.executable,
        step.arguments,
        environment: step.environment,
        workingDirectory: step.workingDirectory,
      );
    }
    if (!File.fromUri(plan.outputFile).existsSync()) {
      throw StateError('build finished but ${plan.outputFile} is missing');
    }
    return plan.outputFile;
  }

  Future<ProcessResult> _run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) => Process.run(
    executable,
    arguments,
    environment: environment,
    workingDirectory: workingDirectory,
    includeParentEnvironment: true,
  );

  Future<ProcessResult> _runOrThrow(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final ProcessResult result;
    try {
      result = await _run(
        executable,
        arguments,
        environment: environment,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (e) {
      throw StateError('cannot run $executable: ${e.message}');
    }
    if (result.exitCode != 0) {
      throw StateError(
        '`$executable ${arguments.join(' ')}` failed (exit ${result.exitCode})\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
    return result;
  }
}
