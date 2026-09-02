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
/// Empty until the first native release is published; until then the hook
/// needs `build_from_source` or `prebuilt_dir`.
const nativeArtifacts = <String, String>{};

/// Download URL for [artifactFileName], or `null` if it is not published.
Uri? nativeArtifactUrl(String artifactFileName) =>
    nativeArtifacts.containsKey(artifactFileName)
    ? Uri.parse('$nativeReleaseBaseUrl/$nativeReleaseTag/$artifactFileName')
    : null;
