// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Build hook: provides `libtailscale.{dylib,so}` for the target platform and
/// registers it (plus an in-process libc lookup) as code assets.
///
/// See `lib/src/hook/user_config.dart` for the configuration knobs.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'package:libtailscale/src/hook/native_target.dart';
import 'package:libtailscale/src/hook/resolver.dart';
import 'package:libtailscale/src/hook/user_config.dart';

/// Asset id of the generated `tailscale_*` bindings.
const tailscaleAssetName = 'src/ffi/tailscale_bindings.g.dart';

/// Asset id of the hand-written libc bindings.
const libcAssetName = 'src/ffi/libc.dart';

/// Asset id of the dev-only hermetic test control server.
const testControlAssetName = 'src/testing/tstestcontrol.dart';

void main(List<String> arguments) => build(arguments, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final code = input.config.code;
  final package = input.packageName;

  // libc symbols (read/write/poll/...) are resolved in the running
  // process on every supported platform; no library to ship.
  output.assets.code.add(
    CodeAsset(
      package: package,
      name: libcAssetName,
      linkMode: LookupInProcess(),
    ),
  );

  final target = NativeTarget.fromCodeConfig(code);
  final config = HookUserConfig.from(input);
  // Re-run when the developer override file changes or gets created. Only
  // this package's own pubspec names one; applications never pay for it.
  final localConfig = HookUserConfig.localConfigFile(input);
  if (localConfig != null) output.dependencies.add(localConfig.uri);
  final resolver = NativeLibraryResolver(
    target: target,
    config: config,
    outputDirectory: input.outputDirectory,
    sharedDirectory: input.outputDirectoryShared,
    cCompiler: code.cCompiler,
    packageRoot: input.packageRoot,
    log: stderr.writeln,
  );
  final resolved = await resolver.resolve();
  if (resolved != null) {
    output.assets.code.add(
      CodeAsset(
        package: package,
        name: tailscaleAssetName,
        linkMode: DynamicLoadingBundled(),
        file: resolved.file,
      ),
    );
    output.dependencies.addAll(resolved.dependencies);
  }

  if (config.buildTestControl) {
    final testControl = await resolver.resolveTestControl();
    output.assets.code.add(
      CodeAsset(
        package: package,
        name: testControlAssetName,
        linkMode: DynamicLoadingBundled(),
        file: testControl.file,
      ),
    );
    output.dependencies.addAll(testControl.dependencies);
  }
});
