// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../../hook/build.dart' as hook;
import '../../hook/src/artifact_download.dart';
import '../../hook/src/go_build.dart';
import '../../hook/src/native_manifest.dart';
import '../../hook/src/native_target.dart';
import '../../hook/src/resolver.dart';
import '../../hook/src/user_config.dart';

void main() {
  group('NativeTarget', () {
    test('artifact keys and file names', () {
      const mac = NativeTarget(os: OS.macOS, architecture: Architecture.arm64);
      expect(mac.artifactKey, 'libtailscale-macos-arm64');
      expect(mac.artifactFileName, 'libtailscale-macos-arm64.dylib');
      expect(mac.libraryFileName, 'libtailscale.dylib');
      expect(mac.goos, 'darwin');
      expect(mac.goarch, 'arm64');
      expect(mac.isSupported, isTrue);

      const sim = NativeTarget(
        os: OS.iOS,
        architecture: Architecture.x64,
        iosSdk: IOSSdk.iPhoneSimulator,
      );
      expect(sim.artifactKey, 'libtailscale-ios-x64-iphonesimulator');
      expect(sim.goarch, 'amd64');
      expect(sim.isSupported, isTrue);
      expect(
        const NativeTarget(
          os: OS.iOS,
          architecture: Architecture.x64,
          iosSdk: IOSSdk.iPhoneOS,
        ).isSupported,
        isFalse,
      );

      const android = NativeTarget(
        os: OS.android,
        architecture: Architecture.arm,
      );
      expect(android.libraryFileName, 'libtailscale.so');
      expect(android.artifactFileName, 'libtailscale-android-arm.so');
      expect(android.goarch, 'arm');

      const win = NativeTarget(os: OS.windows, architecture: Architecture.x64);
      expect(win.isSupported, isFalse);
      expect(win.unsupportedReason, contains('Windows'));
    });

    test('clamps deployment targets to the supported minimums', () {
      expect(
        const NativeTarget(
          os: OS.macOS,
          architecture: Architecture.arm64,
          macosVersion: 13,
        ).effectiveMacosVersion,
        15,
      );
      expect(
        const NativeTarget(
          os: OS.macOS,
          architecture: Architecture.arm64,
          macosVersion: 16,
        ).effectiveMacosVersion,
        16,
      );
      expect(
        const NativeTarget(
          os: OS.android,
          architecture: Architecture.arm64,
          androidNdkApi: 30,
        ).effectiveAndroidApi,
        35,
      );
      expect(
        const NativeTarget(
          os: OS.iOS,
          architecture: Architecture.arm64,
          iosVersion: 12,
        ).effectiveIosVersion,
        15,
      );
    });
  });

  group('GoBuildPlan', () {
    final src = Uri.parse('file:///src/libtailscale/');
    final out = Uri.parse('file:///out/');

    test('macOS uses c-shared with the Sequoia deployment target', () {
      final plan = GoBuildPlan.forTarget(
        const NativeTarget(
          os: OS.macOS,
          architecture: Architecture.x64,
          macosVersion: 15,
        ),
        sourceDir: src,
        outputDir: out,
      );
      expect(plan.steps, hasLength(1));
      final step = plan.steps.single;
      expect(step.executable, 'go');
      expect(
        step.arguments,
        containsAll(['-buildmode=c-shared', '-trimpath', '-buildvcs=false']),
      );
      expect(step.arguments.last, '.');
      expect(step.environment['GOOS'], 'darwin');
      expect(step.environment['GOARCH'], 'amd64');
      expect(step.environment['CGO_ENABLED'], '1');
      expect(step.environment['GOTOOLCHAIN'], 'go1.25.5+auto');
      expect(step.environment['MACOSX_DEPLOYMENT_TARGET'], '15.0');
      expect(step.environment['CGO_CFLAGS'], '-mmacos-version-min=15.0');
      expect(
        step.environment['CGO_LDFLAGS'],
        '-mmacos-version-min=15.0 -Wl,-headerpad_max_install_names',
      );
      expect(step.workingDirectory, '/src/libtailscale/');
      expect(plan.outputFile.path, '/out/libtailscale.dylib');
    });

    test('Android requires the NDK compiler and 16 KB page alignment', () {
      const target = NativeTarget(
        os: OS.android,
        architecture: Architecture.arm64,
        androidNdkApi: 35,
      );
      expect(
        () => GoBuildPlan.forTarget(target, sourceDir: src, outputDir: out),
        throwsStateError,
      );
      final ndk = CCompilerConfig(
        compiler: Uri.parse('file:///ndk/bin/aarch64-linux-android35-clang'),
        linker: Uri.parse('file:///ndk/bin/ld'),
        archiver: Uri.parse('file:///ndk/bin/ar'),
      );
      expect(
        () => GoBuildPlan.forTarget(
          target,
          sourceDir: src,
          outputDir: out,
          cCompiler: ndk,
        ),
        throwsStateError,
        reason: 'the netmon interface getter source is required',
      );
      final plan = GoBuildPlan.forTarget(
        target,
        sourceDir: src,
        outputDir: out,
        cCompiler: ndk,
        androidOverlaySource: Uri.file('/pkg/hook/go/android_interfaces.go'),
      );
      final env = plan.steps.single.environment;
      expect(env['CC'], '/ndk/bin/aarch64-linux-android35-clang');
      expect(
        plan.steps.single.arguments,
        containsAllInOrder(['-overlay', '/out/overlay-android.json']),
      );
      final overlay = plan.extraFiles.single;
      expect(overlay.path.toFilePath(), '/out/overlay-android.json');
      expect(overlay.executable, isFalse);
      expect(jsonDecode(overlay.contents), {
        'Replace': {
          '/src/libtailscale/zz_libtailscale_dart_android_interfaces.go':
              '/pkg/hook/go/android_interfaces.go',
        },
      });
      expect(env['GOOS'], 'android');
      expect(env['CGO_LDFLAGS'], contains('max-page-size=16384'));
      expect(env['CGO_CFLAGS'], '--target=aarch64-linux-android35');
      expect(
        env['CGO_LDFLAGS'],
        startsWith('--target=aarch64-linux-android35 '),
      );
      expect(env['CGO_LDFLAGS'], contains('-soname,libtailscale.so'));
      expect(plan.outputFile.path, '/out/libtailscale.so');
    });

    test('iOS builds a c-archive with a clang wrapper, then links a dylib', () {
      const target = NativeTarget(
        os: OS.iOS,
        architecture: Architecture.arm64,
        iosSdk: IOSSdk.iPhoneSimulator,
        iosVersion: 15,
      );
      expect(
        () => GoBuildPlan.forTarget(target, sourceDir: src, outputDir: out),
        throwsStateError,
        reason: 'needs the SDK path',
      );
      final plan = GoBuildPlan.forTarget(
        target,
        sourceDir: src,
        outputDir: out,
        iosSdkPath: '/Xcode/SDKs/iPhoneSimulator.sdk',
      );
      expect(plan.steps, hasLength(2));
      final go = plan.steps[0];
      expect(
        go.arguments,
        containsAll(['-buildmode=c-archive', '-tags', 'ios']),
      );
      expect(go.environment['GOOS'], 'ios');
      expect(
        go.environment['CC'],
        endsWith('clangwrap-iphonesimulator-arm64.sh'),
      );
      final (path: wrapperUri, contents: script, executable: _) =
          plan.extraFiles.single;
      expect(wrapperUri.path, '/out/clangwrap-iphonesimulator-arm64.sh');
      expect(script, contains('-mios-simulator-version-min=15.0'));
      expect(script, contains('-isysroot "/Xcode/SDKs/iPhoneSimulator.sdk"'));
      final link = plan.steps[1];
      expect(link.executable, 'xcrun');
      expect(
        link.arguments,
        containsAll(['-dynamiclib', '-Wl,-all_load', '-lresolv']),
      );
      expect(
        link.arguments,
        contains('@rpath/libtailscale.framework/libtailscale'),
      );
      expect(link.arguments.last, '/out/libtailscale.dylib');
    });

    test('iOS device uses the iphoneos SDK flags', () {
      final plan = GoBuildPlan.forTarget(
        const NativeTarget(
          os: OS.iOS,
          architecture: Architecture.arm64,
          iosSdk: IOSSdk.iPhoneOS,
        ),
        sourceDir: src,
        outputDir: out,
        iosSdkPath: '/sdk',
      );
      expect(
        plan.extraFiles.single.contents,
        contains('-miphoneos-version-min=15.0'),
      );
      expect(plan.steps[1].arguments, contains('iphoneos'));
    });

    test('Linux passes an optional cross compiler', () {
      final plan = GoBuildPlan.forTarget(
        const NativeTarget(os: OS.linux, architecture: Architecture.arm64),
        sourceDir: src,
        outputDir: out,
        cCompiler: CCompilerConfig(
          compiler: Uri.parse('file:///usr/bin/aarch64-linux-gnu-gcc'),
          linker: Uri.parse('file:///usr/bin/ld'),
          archiver: Uri.parse('file:///usr/bin/ar'),
        ),
      );
      expect(
        plan.steps.single.environment['CC'],
        '/usr/bin/aarch64-linux-gnu-gcc',
      );
      expect(plan.steps.single.environment['GOOS'], 'linux');
      final local = GoBuildPlan.forTarget(
        const NativeTarget(os: OS.linux, architecture: Architecture.x64),
        sourceDir: src,
        outputDir: out,
        goToolchain: 'local',
      );
      expect(local.steps.single.environment['GOTOOLCHAIN'], 'local');
    });

    test('unsupported targets throw', () {
      expect(
        () => GoBuildPlan.forTarget(
          const NativeTarget(os: OS.windows, architecture: Architecture.x64),
          sourceDir: src,
          outputDir: out,
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('HookUserConfig', () {
    test('resolves pubspec user-defines', () {
      final defines = <String, Object?>{
        'build_from_source': 'true',
        'prebuilt_dir': '/opt/libs',
        'go': '/usr/local/go/bin/go',
        'allow_missing_native': false,
      };
      final config = HookUserConfig.resolve(
        value: (k) => defines[k],
        path: (k) =>
            defines[k] is String ? Uri.file(defines[k]! as String) : null,
      );
      expect(config.buildFromSource, isTrue);
      expect(
        config.prebuiltDir,
        Uri.file('/opt/libs/'),
        reason: 'trailing slash',
      );
      expect(config.goExecutable, '/usr/local/go/bin/go');
      expect(config.allowMissingNative, isFalse);
      expect(config.buildTestControl, isFalse);
      expect(config.sourceDir, isNull);
    });

    test('local override file wins and resolves relative paths', () async {
      final temp = await Directory.systemTemp.createTemp('libtailscale-local');
      try {
        final root = temp.uri;
        final file = File.fromUri(root.resolve('hook/local_config.json'));
        expect(LocalHookConfig.read(file), isNull);
        file.createSync(recursive: true);
        file.writeAsStringSync(
          '{"build_from_source": true, "source_dir": "../upstream", "build_test_control": 1}',
        );
        final local = LocalHookConfig.read(file)!;
        expect(local.has('build_from_source'), isTrue);
        expect(local.has('prebuilt_dir'), isFalse);
        expect(local.path('source_dir'), root.resolve('upstream'));

        final defines = <String, Object?>{
          'build_from_source': false,
          'go': 'go2',
        };
        final config = HookUserConfig.resolve(
          value: (k) => local.has(k) ? local.value(k) : defines[k],
          path: (k) => local.has(k) ? local.path(k) : null,
        );
        expect(
          config.buildFromSource,
          isTrue,
          reason: 'local overrides pubspec',
        );
        expect(config.buildTestControl, isTrue);
        expect(config.goExecutable, 'go2', reason: 'falls through to pubspec');
        expect(config.sourceDir!.path, endsWith('/upstream/'));

        file.writeAsStringSync('[1, 2]');
        expect(() => LocalHookConfig.read(file), throwsA(isA<BuildError>()));
        file.writeAsStringSync('not json');
        expect(() => LocalHookConfig.read(file), throwsA(isA<BuildError>()));
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });

  group('ArtifactDownloader', () {
    late HttpServer server;
    var hits = 0;
    final content = List<int>.generate(1000, (i) => i % 251);
    late String digest;
    late Directory temp;

    setUp(() async {
      hits = 0;
      temp = await Directory.systemTemp.createTemp('libtailscale-dl');
      final f = File('${temp.path}/content.bin')..writeAsBytesSync(content);
      digest = await sha256OfFile(f);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        hits++;
        if (req.uri.path == '/missing') {
          req.response.statusCode = 404;
        } else {
          req.response.add(content);
        }
        req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    test('downloads, verifies and caches', () async {
      final dl = ArtifactDownloader(
        cacheDir: Uri.directory('${temp.path}/cache/'),
        log: (_) {},
      );
      final url = Uri.parse('http://127.0.0.1:${server.port}/lib.dylib');
      final file = await dl.fetch(
        url: url,
        expectedSha256: digest,
        fileName: 'lib.dylib',
      );
      expect(file.readAsBytesSync(), content);
      expect(hits, 1);
      final again = await dl.fetch(
        url: url,
        expectedSha256: digest,
        fileName: 'lib.dylib',
      );
      expect(again.path, file.path);
      expect(hits, 1, reason: 'served from cache');
    });

    test('rejects checksum mismatches and HTTP errors', () async {
      final dl = ArtifactDownloader(
        cacheDir: Uri.directory('${temp.path}/cache/'),
        log: (_) {},
      );
      await expectLater(
        dl.fetch(
          url: Uri.parse('http://127.0.0.1:${server.port}/lib.dylib'),
          expectedSha256: 'f' * 64,
          fileName: 'lib.dylib',
        ),
        throwsStateError,
      );
      expect(
        Directory(
          '${temp.path}/cache',
        ).listSync().where((e) => e.path.endsWith('.part')),
        isEmpty,
      );
      await expectLater(
        dl.fetch(
          url: Uri.parse('http://127.0.0.1:${server.port}/missing'),
          expectedSha256: digest,
          fileName: 'x',
        ),
        throwsA(isA<HttpException>()),
      );
    });
  });

  group('NativeLibraryResolver', () {
    late Directory temp;
    const target = NativeTarget(os: OS.macOS, architecture: Architecture.arm64);

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('libtailscale-resolver');
    });

    tearDown(() => temp.delete(recursive: true));

    NativeLibraryResolver resolver(HookUserConfig config) =>
        NativeLibraryResolver(
          target: target,
          config: config,
          outputDirectory: Uri.directory('${temp.path}/out/'),
          sharedDirectory: Uri.directory('${temp.path}/shared/'),
          log: (_) {},
        );

    test('copies a prebuilt library under the constant name', () async {
      final dir = Directory('${temp.path}/prebuilt')..createSync();
      File(
        '${dir.path}/libtailscale-macos-arm64.dylib',
      ).writeAsStringSync('fake');
      final result = await resolver(
        HookUserConfig(prebuiltDir: dir.uri),
      ).resolve();
      expect(result!.source, NativeLibrarySource.prebuilt);
      expect(result.file.path, endsWith('/out/libtailscale.dylib'));
      expect(File.fromUri(result.file).readAsStringSync(), 'fake');
      expect(
        result.dependencies.single.path,
        endsWith('libtailscale-macos-arm64.dylib'),
      );
    });

    test('fails clearly when prebuilt_dir has no library', () async {
      final dir = Directory('${temp.path}/empty')..createSync();
      await expectLater(
        resolver(HookUserConfig(prebuiltDir: dir.uri)).resolve(),
        throwsA(isA<BuildError>()),
      );
    });

    test(
      'a failed download is fatal unless allow_missing_native is set',
      () async {
        expect(
          nativeArtifactUrl(target.artifactFileName),
          isNotNull,
          reason: 'the manifest pins every release target',
        );
        final log = <String>[];
        NativeLibraryResolver offline(HookUserConfig config) =>
            NativeLibraryResolver(
              target: target,
              config: config,
              outputDirectory: Uri.directory('${temp.path}/out/'),
              sharedDirectory: Uri.directory('${temp.path}/shared/'),
              log: log.add,
              downloader: ArtifactDownloader(
                cacheDir: Uri.directory('${temp.path}/shared/'),
                log: log.add,
                createHttpClient: _OfflineHttpClient.new,
              ),
            );
        expect(
          await offline(
            const HookUserConfig(allowMissingNative: true),
          ).resolve(),
          isNull,
        );
        expect(log.join('\n'), contains('allow_missing_native'));
        await expectLater(
          offline(const HookUserConfig()).resolve(),
          throwsA(
            isA<BuildError>().having(
              (e) => e.message,
              'message',
              contains('build_from_source'),
            ),
          ),
        );
      },
    );

    test('rejects unsupported targets', () async {
      final r = NativeLibraryResolver(
        target: const NativeTarget(
          os: OS.windows,
          architecture: Architecture.x64,
        ),
        config: const HookUserConfig(allowMissingNative: true),
        outputDirectory: Uri.directory('${temp.path}/out/'),
        sharedDirectory: Uri.directory('${temp.path}/shared/'),
        log: (_) {},
      );
      await expectLater(r.resolve(), throwsA(isA<BuildError>()));
    });
  });

  group('hook/build.dart', () {
    // Needs network access to github.com; `dart test -x network` skips it.
    void networkTest(String name, Future<void> Function() body) {
      test(name, body, tags: 'network');
    }

    networkTest(
      'downloads and verifies the pinned library by default',
      () async {
        final target = NativeTarget(
          os: OS.current,
          architecture: Architecture.current,
        );
        await testCodeBuildHook(
          mainMethod: hook.main,
          userDefines: PackageUserDefines(
            workspacePubspec: PackageUserDefinesSource(
              // Ignore the developer's hook/local_config.json.
              defines: {'local_config': 'none.json'},
              basePath: Directory.current.uri,
            ),
          ),
          check: (input, output) {
            final assets = output.assets.code;
            expect(assets, hasLength(2));
            final libc = assets.firstWhere((a) => a.id.endsWith('libc.dart'));
            expect(libc.linkMode, isA<LookupInProcess>());
            final lib = assets.firstWhere(
              (a) => a.id.endsWith('tailscale_bindings.g.dart'),
            );
            expect(lib.linkMode, isA<DynamicLoadingBundled>());
            final bytes = File.fromUri(lib.file!).readAsBytesSync();
            expect(
              sha256.convert(bytes).toString(),
              nativeArtifacts[target.artifactFileName],
            );
          },
        );
      },
    );

    test('bundles a prebuilt library from prebuilt_dir', () async {
      final temp = await Directory.systemTemp.createTemp('libtailscale-hook');
      try {
        final target = NativeTarget(
          os: OS.current,
          architecture: Architecture.current,
        );
        File(
          '${temp.path}/${target.libraryFileName}',
        ).writeAsStringSync('not really a library');
        await testCodeBuildHook(
          mainMethod: hook.main,
          userDefines: PackageUserDefines(
            workspacePubspec: PackageUserDefinesSource(
              defines: {'prebuilt_dir': temp.path, 'local_config': 'none.json'},
              basePath: Directory.current.uri,
            ),
          ),
          check: (input, output) {
            final assets = output.assets.code;
            expect(
              assets.map((a) => a.id),
              containsAll([
                'package:libtailscale/src/ffi/libc.dart',
                'package:libtailscale/src/ffi/tailscale_bindings.g.dart',
              ]),
            );
            final lib = assets.firstWhere(
              (a) => a.id.endsWith('tailscale_bindings.g.dart'),
            );
            expect(lib.linkMode, isA<DynamicLoadingBundled>());
            expect(lib.file!.path, endsWith('/${target.libraryFileName}'));
            expect(File.fromUri(lib.file!).existsSync(), isTrue);
            expect(output.dependencies, isNotEmpty);
          },
        );
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });
}

/// An [HttpClient] whose every request fails as if the machine were offline.
final class _OfflineHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      throw const SocketException('offline');

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
