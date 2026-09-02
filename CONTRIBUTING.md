# Contributing

## Development

```sh
git submodule update --init                 # upstream sources (header, Go code)
dart test                                   # unit, libc/reactor and download tests
dart test -x native -x network              # pure Dart only; works offline
echo '{"build_from_source": true, "build_test_control": true}' > hook/local_config.json
LIBTAILSCALE_INTEGRATION=1 dart test -t integration          # hermetic end-to-end tests (needs Go)
(cd tool/ffigen && dart run bin/generate.dart)               # regenerate the FFI bindings
dart run tool/build_native.dart --os macos --arch arm64 --out build/native
```

Build hooks run with a filtered environment, so environment variables cannot
configure the build. While working on this package, the git-ignored
`hook/local_config.json` takes the same keys as the pubspec user-defines and
overrides them; `build_test_control` additionally builds upstream's
`tstestcontrol` for the hermetic tests. The file is only read because this
package's own `pubspec.yaml` names it through the `local_config` user-define;
applications, including the examples here, never inherit it.

The package's own `pubspec.yaml` also sets `allow_missing_native: true`, so
the pure-Dart tests still run when the library can be neither built nor
downloaded. Tests that need it skip themselves.

CI (`.github/workflows/ci.yml`) formats, analyzes and runs the unit tests on
Ubuntu and macOS with Flutter stable's Dart SDK, runs the hermetic tests with
Go, and does a `pub publish --dry-run`. The examples are analyzed only; they set
`build_from_source`, so testing them would compile libtailscale on every run.

pub.dev accepts only `hook/build.dart` and `hook/link.dart` under `hook/`. The
hook's helpers and the Android Go overlay therefore live in `lib/src/hook/`.

## Cutting a native release

A new native release is needed when the shared library would change: an
upstream bump, a change to `lib/src/hook/android_interfaces.go`, or a change
to the build plan in `lib/src/hook/go_build.dart`. Pure Dart changes reuse the
pinned release.

1. Move the `third_party/libtailscale` submodule to the new upstream commit and
   update `upstreamCommit`, `upstreamTailscaleVersion` and `minimumGoVersion`
   in `lib/src/hook/native_manifest.dart`. Run the hermetic tests.
2. Start the **Native release** workflow from the Actions tab with a
   `native-vX.Y.Z` tag, or push that tag. It builds the ten libraries in
   `NativeTarget.releaseTargets`, publishes them with `SHA256SUMS` as a GitHub
   release, downloads every asset back to verify it, and pushes a
   `native-manifest/native-vX.Y.Z` branch that pins the digests. Opening a
   pull request for that branch needs "Allow GitHub Actions to create and
   approve pull requests" in the repository's and the organization's Actions
   settings; without it, open the pull request by hand or pin the checksums
   locally:

   ```sh
   gh release download native-vX.Y.Z --pattern SHA256SUMS
   dart run tool/update_manifest.dart --sums SHA256SUMS --tag native-vX.Y.Z
   ```

3. Merge the manifest change, then publish a package version as described
   below. Consumers only receive new binaries through a new package version.

Never delete an old `native-v*` release: every published package version
downloads from the release it pinned. Verify a checkout against a release with
`dart run tool/update_manifest.dart --sums SHA256SUMS --tag native-vX.Y.Z --check`.

## Publishing

Bump `version:` in `pubspec.yaml`, update `CHANGELOG.md`, commit, and push a
`vX.Y.Z` tag. `.github/workflows/publish.yml` checks that the tag matches the
pubspec version, skips versions that are already on pub.dev, and otherwise
publishes through pub.dev's automated publishing.

## Repository layout

| Path | Contents |
|---|---|
| `lib/`, `hook/`, `test/` | The package: bindings, runtime, public API, build hook (`hook/build.dart` plus `lib/src/hook/`), tests. |
| `tool/` | `build_native.dart` (release builds), `update_manifest.dart` (pins release checksums) and the ffigen tool package. |
| `example/` | `example.dart`, the single-file example shown on pub.dev. |
| `examples/tsnode/`, `examples/node_console/` | The `tsnode` CLI and the Flutter app (repository only, not in the pub archive). |
| `third_party/libtailscale/` | Upstream sources as a git submodule, pinned to the commit the native libraries are built from. Excluded from the pub archive. |
| `specs/` | Design plan and research notes. |
