// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:code_assets/code_assets.dart';

/// The platform a native libtailscale library is built for.
///
/// Pure data: it maps Dart/Flutter's target description to Go's `GOOS` /
/// `GOARCH`, to the artifact name used on the release page and to the file
/// name Flutter expects (identical across architectures of one OS).
final class NativeTarget {
  /// Creates a target.
  const NativeTarget({
    required this.os,
    required this.architecture,
    this.iosSdk,
    this.androidNdkApi,
    this.macosVersion,
    this.iosVersion,
  });

  /// Reads the target from a build hook's code configuration.
  factory NativeTarget.fromCodeConfig(CodeConfig code) => NativeTarget(
    os: code.targetOS,
    architecture: code.targetArchitecture,
    iosSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
    iosVersion: code.targetOS == OS.iOS ? code.iOS.targetVersion : null,
    androidNdkApi: code.targetOS == OS.android
        ? code.android.targetNdkApi
        : null,
    macosVersion: code.targetOS == OS.macOS ? code.macOS.targetVersion : null,
  );

  /// Every target a native release publishes, in `SHA256SUMS` order. The
  /// release workflow's matrix and `tool/update_manifest.dart` follow this
  /// list.
  static const List<NativeTarget> releaseTargets = [
    NativeTarget(os: OS.macOS, architecture: Architecture.arm64),
    NativeTarget(os: OS.macOS, architecture: Architecture.x64),
    NativeTarget(
      os: OS.iOS,
      architecture: Architecture.arm64,
      iosSdk: IOSSdk.iPhoneOS,
    ),
    NativeTarget(
      os: OS.iOS,
      architecture: Architecture.arm64,
      iosSdk: IOSSdk.iPhoneSimulator,
    ),
    NativeTarget(
      os: OS.iOS,
      architecture: Architecture.x64,
      iosSdk: IOSSdk.iPhoneSimulator,
    ),
    NativeTarget(os: OS.linux, architecture: Architecture.x64),
    NativeTarget(os: OS.linux, architecture: Architecture.arm64),
    NativeTarget(os: OS.android, architecture: Architecture.arm64),
    NativeTarget(os: OS.android, architecture: Architecture.x64),
    NativeTarget(os: OS.android, architecture: Architecture.arm),
  ];

  /// Minimum macOS version the library declares (Sequoia).
  static const int minimumMacosVersion = 15;

  /// Minimum iOS version the library declares.
  static const int minimumIosVersion = 15;

  /// Minimum Android API level (Android 15).
  static const int minimumAndroidApi = 35;

  /// Target OS.
  final OS os;

  /// Target CPU architecture.
  final Architecture architecture;

  /// Device or simulator SDK (iOS only).
  final IOSSdk? iosSdk;

  /// Android NDK API level (Android only).
  final int? androidNdkApi;

  /// Deployment target major version (macOS only).
  final int? macosVersion;

  /// Deployment target major version (iOS only).
  final int? iosVersion;

  /// Whether libtailscale can be built for this target at all.
  bool get isSupported => switch (os) {
    OS.macOS =>
      architecture == Architecture.arm64 || architecture == Architecture.x64,
    OS.linux =>
      architecture == Architecture.arm64 || architecture == Architecture.x64,
    OS.iOS =>
      architecture == Architecture.arm64 ||
          (architecture == Architecture.x64 &&
              iosSdk == IOSSdk.iPhoneSimulator),
    OS.android =>
      architecture == Architecture.arm64 ||
          architecture == Architecture.x64 ||
          architecture == Architecture.arm,
    _ => false,
  };

  /// Why the target is unsupported, for error messages.
  String get unsupportedReason => switch (os) {
    OS.windows =>
      'libtailscale does not compile for Windows (it relies on '
          'Unix socketpair(2) and SCM_RIGHTS); see the README',
    OS.macOS ||
    OS.linux ||
    OS.iOS ||
    OS.android => '$architecture is not supported on $os',
    _ => '$os is not supported',
  };

  /// `GOOS` for this target.
  String get goos => switch (os) {
    OS.macOS => 'darwin',
    OS.iOS => 'ios',
    OS.linux => 'linux',
    OS.android => 'android',
    _ => throw UnsupportedError(unsupportedReason),
  };

  /// `GOARCH` for this target.
  String get goarch => switch (architecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'amd64',
    Architecture.arm => 'arm',
    Architecture.ia32 => '386',
    Architecture.riscv64 => 'riscv64',
    _ => throw UnsupportedError(unsupportedReason),
  };

  /// The file name Flutter bundles; the same for every architecture of an OS.
  String get libraryFileName => os == OS.linux || os == OS.android
      ? 'libtailscale.so'
      : 'libtailscale.dylib';

  /// File extension of [libraryFileName].
  String get libraryExtension =>
      os == OS.linux || os == OS.android ? 'so' : 'dylib';

  /// Unique key of the prebuilt artifact, e.g. `libtailscale-ios-arm64-iphonesimulator`.
  String get artifactKey {
    final sdk = iosSdk;
    final suffix = sdk == null ? '' : '-${sdk.type}';
    return 'libtailscale-${os.name}-${architecture.name}$suffix';
  }

  /// File name of the prebuilt artifact on the release page.
  String get artifactFileName => '$artifactKey.$libraryExtension';

  /// Effective macOS deployment target (never below [minimumMacosVersion]).
  int get effectiveMacosVersion {
    final v = macosVersion ?? minimumMacosVersion;
    return v < minimumMacosVersion ? minimumMacosVersion : v;
  }

  /// Effective iOS deployment target (never below [minimumIosVersion]).
  int get effectiveIosVersion {
    final v = iosVersion ?? minimumIosVersion;
    return v < minimumIosVersion ? minimumIosVersion : v;
  }

  /// Effective Android API level (never below [minimumAndroidApi]).
  int get effectiveAndroidApi {
    final v = androidNdkApi ?? minimumAndroidApi;
    return v < minimumAndroidApi ? minimumAndroidApi : v;
  }

  @override
  String toString() => artifactKey;
}
