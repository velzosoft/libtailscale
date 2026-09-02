// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Pinned upstream sources and prebuilt native artifacts.
///
/// The release workflow (`.github/workflows/native-release.yml`) runs
/// `tool/update_manifest.dart`, which rewrites [nativeReleaseTag] and
/// [nativeArtifacts] from the release's `SHA256SUMS`; the values are
/// committed so that every consumer verifies the same bytes.
library;

/// Upstream libtailscale repository.
const upstreamRepository = 'https://github.com/tailscale/libtailscale';

/// Upstream commit the native libraries are built from (also the
/// `third_party/libtailscale` submodule revision).
const upstreamCommit = '59d4bb82744915815178e0f0776d60026a397ee7';

/// `tailscale.com` version pinned by that commit's `go.mod`.
const upstreamTailscaleVersion = 'v1.94.1';

/// Minimum Go toolchain for source builds (upstream `go.mod` directive).
const minimumGoVersion = '1.25.5';

/// `GOTOOLCHAIN` value used for source builds.
///
/// Newer Go releases break the pinned tailscale dependency set (Go 1.27
/// changed the `encoding/json/v2` API that `go-json-experiment/json` aliases),
/// so the hook asks `go` to use exactly the upstream version, downloading it
/// on first use. The `+auto` suffix still lets `go.mod` demand something
/// newer. Override with the `go_toolchain` user-define (`local` keeps the
/// installed toolchain).
const defaultGoToolchain = 'go$minimumGoVersion+auto';

/// Release tag holding the prebuilt libraries.
const nativeReleaseTag = 'native-v0.1.0';

/// Base URL of GitHub release downloads.
const nativeReleaseBaseUrl =
    'https://github.com/velzosoft/libtailscale/releases/download';

/// SHA-256 (hex) of every prebuilt artifact, keyed by
/// `NativeTarget.artifactFileName`. Generated; do not edit by hand.
///
/// Covers every `NativeTarget.releaseTargets` entry of [nativeReleaseTag];
/// `tool/update_manifest.dart` regenerates it from a release's `SHA256SUMS`.
const nativeArtifacts = <String, String>{
  'libtailscale-macos-arm64.dylib':
      'f977313a9ce64217192bcf08e2bbe25fc19f6c532e0cd039fd5b9b29bd7ef591',
  'libtailscale-macos-x64.dylib':
      '8715064fae70e3603481b6d834ceaa772d28ab4961c055524cc6bba295a63460',
  'libtailscale-ios-arm64-iphoneos.dylib':
      '9cb55bc0046a9bd64e47bc32ed1fb3e57394092390ca36e3ce0f4a2a69fce5d3',
  'libtailscale-ios-arm64-iphonesimulator.dylib':
      'e2d2a26b6c7840ac6189508744d3ba1e9473029aec1ce41c92a7d953f005ed59',
  'libtailscale-ios-x64-iphonesimulator.dylib':
      '695e758074b0f9cd3161f8cb26fae1479787e8c7f135204094dc8a741afec69c',
  'libtailscale-linux-x64.so':
      'b9030644ac93e5d809e0f428c24df25869d52bf8769fa55adbb126c817fa97e4',
  'libtailscale-linux-arm64.so':
      'b142c7beac954ed15373c4a87b7d85f6ff218929eb04392fdf463f66aaa6dbf5',
  'libtailscale-android-arm64.so':
      'a2178ba9d30e22331c0436c46c40f3a5dc34f93cdbabd8d95f240035e73d4a97',
  'libtailscale-android-x64.so':
      '9880547657cdd43ce16ee0a3ef99318725cd08827d46884e1b25c218b368caab',
  'libtailscale-android-arm.so':
      '4e7834ed426bbe0ca59be4af27c51adf85c88d0e2e799e98f0149d3cec824aa1',
};

/// Download URL for [artifactFileName], or `null` if it is not published.
Uri? nativeArtifactUrl(String artifactFileName) =>
    nativeArtifacts.containsKey(artifactFileName)
    ? Uri.parse('$nativeReleaseBaseUrl/$nativeReleaseTag/$artifactFileName')
    : null;
