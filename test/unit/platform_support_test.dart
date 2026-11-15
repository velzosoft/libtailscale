// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:ffi';

import 'package:libtailscale/src/hook/native_target.dart';
import 'package:libtailscale/src/runtime/platform_support.dart';
import 'package:test/test.dart';

void main() {
  test('accepts the nine ABIs with a native release', () {
    expect(
      Abi.values.where((abi) => unsupportedAbiReason(abi) == null),
      unorderedEquals([
        Abi.macosArm64,
        Abi.macosX64,
        Abi.iosArm64,
        Abi.iosX64,
        Abi.linuxArm64,
        Abi.linuxX64,
        Abi.androidArm64,
        Abi.androidX64,
        Abi.androidArm,
      ]),
    );
  });

  test('explains every other ABI', () {
    for (final abi in [
      Abi.windowsX64,
      Abi.windowsArm64,
      Abi.linuxRiscv64,
      Abi.androidIA32,
      Abi.fuchsiaArm64,
    ]) {
      expect(
        unsupportedAbiReason(abi),
        allOf(contains('$abi'), contains('README')),
        reason: '$abi',
      );
    }
  });

  test("stays in step with the build hook's release targets", () {
    // Abi.toString() is `<os>_<arch>`, e.g. `ios_arm64`, with the same names
    // as package:code_assets' OS and Architecture.
    Abi abiOf(NativeTarget target) => Abi.values.singleWhere(
      (abi) => '$abi' == '${target.os.name}_${target.architecture.name}',
      orElse: () => fail('no Abi for $target'),
    );
    expect(NativeTarget.releaseTargets.every((t) => t.isSupported), isTrue);
    expect(NativeTarget.releaseTargets.map(abiOf).toSet(), supportedAbis);
  });
}
