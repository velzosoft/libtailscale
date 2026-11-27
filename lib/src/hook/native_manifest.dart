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
const upstreamCommit = 'dacde75057ff350e146505829beff446e6823966';

/// `tailscale.com` version pinned by that commit's `go.mod`.
const upstreamTailscaleVersion = 'v1.104.1';

/// Minimum Go toolchain for source builds (upstream `go.mod` directive).
const minimumGoVersion = '1.27.1';

/// `GOTOOLCHAIN` value used for source builds.
///
/// A Go release newer than the pinned tailscale dependency set can break it
/// (Go 1.27 changed the `encoding/json/v2` API that `go-json-experiment/json`
/// aliases, which broke tailscale.com v1.94.1), so the hook asks `go` to use
/// exactly the upstream version, downloading it on first use. The `+auto`
/// suffix still lets `go.mod` demand something newer. Override with the
/// `go_toolchain` user-define (`local` keeps the installed toolchain).
const defaultGoToolchain = 'go$minimumGoVersion+auto';

/// Release tag holding the prebuilt libraries.
const nativeReleaseTag = 'native-v0.2.0';

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
      '8acf53bd798f94bb3d3f6288387113b3b7783cd4281af436927981bf56bc907d',
  'libtailscale-macos-x64.dylib':
      '8df7360d6ea20a1a35b07353dc5b25ad2485f3441d2da323be309d2ef874e4ea',
  'libtailscale-ios-arm64-iphoneos.dylib':
      'aceeabb6060a483a855b28cee1c6777bb9959a3e935f754a15fe1953d03b4fe8',
  'libtailscale-ios-arm64-iphonesimulator.dylib':
      'afd5e26b0f62bdedb08019a28d8aeefec848a618a6345d6bab540e94d0348718',
  'libtailscale-ios-x64-iphonesimulator.dylib':
      '436d5aaebd2d5d7f295284d4611f15c81e01ccb450e1bb84738e29bf333e27e9',
  'libtailscale-linux-x64.so':
      '0ec0b6dde9436ac309b05751cd89bf97de52f6e394263d90c54928e30ee58aca',
  'libtailscale-linux-arm64.so':
      'e3e042828280b3531ac33e6aa42bd199bb0dde60545e8ad322bffa8fc3ea5954',
  'libtailscale-android-arm64.so':
      'ee6b607e17549dbe692ac300538ba3fda2a200b3b2649c25075ed16eaaba30a1',
  'libtailscale-android-x64.so':
      '4ef65d6abeb80cb7543a80d54f56d3b5e54832fa0220049758709f555eec5e59',
  'libtailscale-android-arm.so':
      '3896680aeab77aeabb92efe5e2f4b911868cc16e3d0ba9828a20d8ee4c62ba5b',
};

/// Download URL for [artifactFileName], or `null` if it is not published.
Uri? nativeArtifactUrl(String artifactFileName) =>
    nativeArtifacts.containsKey(artifactFileName)
    ? Uri.parse('$nativeReleaseBaseUrl/$nativeReleaseTag/$artifactFileName')
    : null;
