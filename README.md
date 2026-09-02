# libtailscale

A **headless** Tailscale / Headscale node for Dart and Flutter, embedded in your
process through `dart:ffi` bindings to the official
[libtailscale](https://github.com/tailscale/libtailscale) C library.

The host application supplies a control-server URL and a credential; the
library joins the tailnet and exposes just enough to **control** the node and
**operate** over it. It renders nothing, opens no browser and has no platform
channels.

```dart
import 'package:libtailscale/libtailscale.dart';

final node = TailscaleNode(TailscaleConfig(
  controlUrl: Uri.parse('https://headscale.example.com'), // omit for Tailscale
  credential: const TailscaleCredential.authKey('tskey-auth-…'),
  hostname: 'inventory-agent',
  stateDir: '/path/to/writable/state',
  ephemeral: true,
));

await node.start();
await node.waitUntilRunning(timeout: const Duration(seconds: 60));
print(node.addresses.ipv4);                    // 100.x.y.z

final server = await node.listen(port: 8080);  // Stream<TailscaleSocket>
server.listen((c) => c.addStream(c));          // echo service on the tailnet

final socket = await node.connect('files', 443);      // dart:io Socket via SOCKS5
final http = node.httpClient();                        // HttpClient over the tailnet
final peers = (await node.status()).peers;             // name, IPs, online, tags, OS

node.stateChanges.listen((s) => print('tailscale: $s'));
await node.close();
```

## Scope

| Area | Included | Deliberately excluded |
|---|---|---|
| Configure | control URL (Tailscale or Headscale); auth / pre-auth key, Tailscale OAuth client, existing state, or interactive login; hostname; state directory; ephemeral | web client, WireGuard port, custom stores |
| Control | `start()`, `waitUntilRunning()`, `close()`, `logout()`, `stateChanges`, `health`, `authUrls` | any UI, browser launching |
| Observe | `addresses`, `status()` with peers, `whoIs(ip)`, `logs` | metrics, bug reports, profiles |
| Operate | `connect()` → `Socket`, `connectSecure()`, `httpClient()`, `listen()`/accept, `dial()`, half-close | UDP, Taildrop, Serve, SSH, exit-node switching |
| Platforms | macOS 15+, iOS 15+, Android 15+ (API 35), Linux with glibc 2.39+ | Windows (libtailscale is Unix-only), web |

Anything else in tailscaled's LocalAPI stays reachable through
`node.localApi.raw(...)`, without compatibility guarantees.

## Credentials

| Credential | Works with | Notes |
|---|---|---|
| `TailscaleCredential.authKey(key)` | Tailscale auth keys, Headscale pre-auth keys | Reusable / ephemeral / tags are properties of the key. |
| `TailscaleCredential.oauthClient(clientId:, clientSecret:, tags:)` | Tailscale only | The library mints a short-lived tagged auth key through the Tailscale API before starting. |
| `TailscaleCredential.existingState()` | both | Reuses the node key in `stateDir`; fails fast with `TailscaleAuthRequiredException` if a login is needed. |
| `TailscaleCredential.interactive()` | both | Publishes the login URL on `node.authUrls`; the app decides what to do with it. On Headscale an admin approves the node with `headscale auth register --auth-id <id from the URL> --user <user>` (`nodes register --key` before 0.29). |

## Headscale

Point `controlUrl` at the Headscale base URL; nothing else changes. Headscale
has no OAuth client API (use pre-auth keys), issues no TLS certificates
(`status.certDomains` is empty) and does not support Funnel or Serve.
`enableFunnelToLocalhost` refuses to run without a certificate domain because
the underlying C call would crash the process.

An unreachable or wrong control URL produces no error from tsnet; the node just
stays in `Starting`/`NeedsLogin`. `waitUntilRunning` therefore always takes a
timeout and reports the last state and health messages in the exception.

## Sockets and TLS

* `connect()` returns a `Socks5Socket`, a real `dart:io` `Socket` tunnelled
  through the node's loopback SOCKS5 proxy. Because the SOCKS handshake consumes
  the raw stream, use `socket.secure(...)` (or `node.connectSecure`) for TLS
  instead of `SecureSocket.secure`.
* `httpClient()` sets `connectionFactory` so `package:http`'s `IOClient`,
  `dio`, gRPC and `WebSocket.connect(customClient:)` work unchanged. Pass a
  `SecurityContext` / bad-certificate callback to `httpClient()` itself.
* `listen()` and `dial()` use libtailscale's file-descriptor path and yield
  `TailscaleSocket` (a `Stream<Uint8List>` + `IOSink`). Dart cannot wrap a
  foreign fd in a `Socket`, so TLS is not available on that path.

Everything that can block runs on helper isolates (`Isolate.run`); a dedicated
isolate drives all fds with a single `poll(2)` loop.

## Build configuration

The package ships no binaries in the pub archive. `hook/build.dart` provides
the native library at build time, in this order:

1. `prebuilt_dir`: a directory containing `libtailscale.{dylib,so}` (or the
   architecture-specific `libtailscale-<os>-<arch>[-<sdk>].<ext>`).
2. `build_from_source`: `go build -buildmode=c-shared` from a pinned upstream
   checkout (any installed Go; the NDK/Xcode toolchains for mobile). The hook
   sets `GOTOOLCHAIN=go1.25.5+auto` so `go` downloads and uses the exact
   version upstream builds with, because newer Go releases break tailscale's
   pinned dependencies; set `go_toolchain: local` to use the installed one.
   iOS is built as a c-archive and linked into a dylib because Go has no
   c-shared mode for `GOOS=ios`.
3. Download of the prebuilt library from this repository's native release,
   verified against the SHA-256 pinned in `hook/src/native_manifest.dart`.

Configure it in the **application's** `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    libtailscale:
      build_from_source: true
      # prebuilt_dir: native/libs
      # source_dir: ../libtailscale
      # go: /usr/local/go/bin/go
```

Hooks run with a filtered environment, so environment variables cannot
configure the build. While developing this package itself, a git-ignored
`hook/local_config.json` takes the same keys and overrides the pubspec
values:

```json
{"build_from_source": true, "build_test_control": true}
```

The file is only read when the root package names it with the
`local_config` user-define, which this package's own `pubspec.yaml` does.
Applications, including the examples in this repository, never inherit it and
configure the hook in their own pubspec as shown above.

> No native release has been published yet, so option 3 is not available:
> use `build_from_source` or `prebuilt_dir`.

### Android

Minimum API 35. The library is linked with 16 KB page alignment and a soname.
Add the `INTERNET` permission to your manifest.

Two Android-only accommodations are built in. Apps may not use netlink
`RTM_GETLINK` since Android 11, which breaks Go's `net.Interfaces()` inside
tsnet; the hook therefore compiles `hook/go/android_interfaces.go` into the
library (through `go build -overlay`, the upstream tree stays untouched),
registering a `getifaddrs(3)`-based interface getter with tailscale's netmon.
And because an app process has no `$HOME` or `$TMPDIR`, which makes tsnet's
log policy panic, `start()` sets both to the state directory when missing, in
the C environment and, through a helper exported by that same Go file, in the
Go runtime's copy of it.

### iOS

Minimum iOS 15. Flutter wraps the dylib in `tailscale.framework` (it drops the `lib` prefix). Userspace
WireGuard stops while the app is suspended; upstream reports the loopback
listener can become stale afterwards, in which case the node falls back to
`tailscale_status_json` for status and `dial()` keeps working. Set
`NSLocalNetworkUsageDescription` (peers on the same LAN are reached directly)
and ship a privacy manifest; the one in `examples/node_console/ios/Runner`
declares the file-timestamp and system-boot-time API categories the Go
runtime and tsnet use.

### Flutter versions

The hook depends on `package:hooks` and `package:code_assets` with ranges that
include the versions pinned by the current Flutter stable (`hooks` 1.0.x,
`code_assets` 1.0.x) as well as the 2.x releases used with a plain Dart SDK.

### Linux

Built on Ubuntu 24.04; requires glibc ≥ 2.39.

## Examples

* [`example/example.dart`](example/example.dart): the whole API in one short
  program: join with an auth key, print node and peers, echo service, dial a
  peer.
* [`examples/tsnode/`](examples/tsnode/): `tsnode`, a headless command-line node
  built on the public API: `join`, `info`, `peers`, `echo`, `send` and `fetch`. Its README
  shows how to try it against Tailscale, Headscale, or the in-process test
  control server without any account.
* [`examples/node_console/`](examples/node_console/): a Flutter app for macOS,
  iOS, Android and Linux with three screens (Connect, Node, Communicate) on top
  of one controller; chat and HTTP fetch interoperate with `tsnode`. See its
  README for the device checklist and the platform settings (entitlements,
  permissions, privacy manifest) an embedding app needs. Both directories under
  `examples/` are repository-only; the pub archive ships `example/example.dart`.

## Development

```sh
git submodule update --init                 # upstream sources (header, Go code)
dart test                                   # unit + libc/reactor tests, no Go needed
dart test -x native                         # pure Dart only
echo '{"build_from_source": true, "build_test_control": true}' > hook/local_config.json
LIBTAILSCALE_INTEGRATION=1 dart test -t integration          # hermetic e2e (Go)
(cd tool/ffigen && dart run bin/generate.dart)               # regenerate bindings
dart run tool/build_native.dart --os macos --arch arm64 --out build/native
```

The package's own `pubspec.yaml` sets `allow_missing_native: true` so the
pure-Dart tests run on machines without Go. That setting only applies when the
package is the root package.

### Cutting a native release

1. Bump the submodule if upstream moved and update `upstreamCommit`,
   `upstreamTailscaleVersion` and `minimumGoVersion` in
   `hook/src/native_manifest.dart`; run the hermetic tests.
2. Start the **Native release** workflow (Actions tab, input `native-vX.Y.Z`,
   or push that tag). It builds the ten libraries in
   `NativeTarget.releaseTargets` on macOS, Linux x64/arm64 and Android runners,
   publishes them with `SHA256SUMS` as a GitHub release, downloads every asset
   back to verify it, and opens a pull request that pins the digests in
   `hook/src/native_manifest.dart` (`tool/update_manifest.dart`).
3. Merge that pull request, bump `version:` in `pubspec.yaml`, update the
   changelog and push a `vX.Y.Z` tag; `publish.yml` publishes to pub.dev.

`dart run tool/update_manifest.dart --sums SHA256SUMS --tag native-vX.Y.Z --check`
verifies a checkout against a release's checksum file.

### Repository layout

| Path | Contents |
|---|---|
| `lib/`, `hook/`, `test/` | The package: bindings, runtime, public API, build hook, tests. |
| `tool/` | `build_native.dart` (release builds), `update_manifest.dart` (pins release checksums) and the ffigen tool package. |
| `example/` | `example.dart`, the single-file example shown on pub.dev. |
| `examples/tsnode/`, `examples/node_console/` | The `tsnode` CLI and the Flutter app (repository only, not in the pub archive). |
| `third_party/libtailscale/` | Upstream sources as a git submodule, pinned to the commit the native libraries are built from. Excluded from the pub archive. |
| `specs/` | Design plan and research notes. |

## Known limitations

* `tailscale_up` is never used: it blocks and cannot be cancelled.
  `waitUntilRunning` implements the same condition in Dart.
* `tailscale_close` does not close listeners or connections; the node tracks
  and closes every fd itself before calling it.
* UDP is not exposed in this version (the fd path loses datagram boundaries;
  SOCKS5 `UDP ASSOCIATE` is planned).
* One pipe write end is intentionally leaked per node started with
  `captureLogs: true`, because Go owns that fd number.

## License

BSD-3-Clause, like libtailscale itself.
