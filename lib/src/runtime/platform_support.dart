// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:ffi';

/// The ABIs a native libtailscale release covers.
///
/// Mirrors `NativeTarget.releaseTargets` in `lib/src/hook/native_target.dart`
/// (the iOS device and simulator targets share [Abi.iosArm64]; Dart's
/// [Abi.iosX64] only exists on the simulator). `platform_support_test.dart`
/// keeps the two lists in step.
const Set<Abi> supportedAbis = {
  Abi.macosArm64,
  Abi.macosX64,
  Abi.iosArm64,
  Abi.iosX64,
  Abi.linuxArm64,
  Abi.linuxX64,
  Abi.androidArm64,
  Abi.androidX64,
  Abi.androidArm,
};

/// Why libtailscale cannot run on [abi], or `null` when it can.
///
/// On such a platform the build hook bundled no native library (the
/// application set `skip_unsupported_targets`), so `TailscaleNode.start()`
/// checks this first and fails with a clear message instead of an FFI
/// symbol-lookup error.
String? unsupportedAbiReason(Abi abi) => supportedAbis.contains(abi)
    ? null
    : 'libtailscale is not available on $abi; see the README for the '
          'supported platforms';
