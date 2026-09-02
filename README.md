# libtailscale

A headless Tailscale / Headscale node for Dart and Flutter. It embeds the
official [libtailscale](https://github.com/tailscale/libtailscale) C library
through `dart:ffi`, joins a tailnet with the credential your app supplies, and
lets the app open and accept connections over it. No UI, no browser, no
platform channels.

Supported: macOS 15+, iOS 15+, Android 15+ (API 35), Linux with glibc 2.39+.
Not supported: Windows and web, because libtailscale is Unix-only.

## Quick start

```yaml
dependencies:
  libtailscale: ^1.0.0
```

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

The prebuilt native library is downloaded and checksum-verified when the app is
built. See [Build configuration](#build-configuration) for the alternatives.

## What is covered

* **Configure**: control URL (Tailscale or Headscale), credential, hostname,
  state directory, ephemeral node.
* **Control**: `start()`, `waitUntilRunning()`, `logout()`, `close()`, and the
  `stateChanges`, `health`, `authUrls` and `logs` streams.
* **Observe**: `addresses`, `status()` with peers and users, `whoIs(ip)`.
* **Operate**: `connect()`, `connectSecure()` and `httpClient()` give you a real
  `dart:io` `Socket` or `HttpClient` over the tailnet; `listen()` and `dial()`
  give you `TailscaleSocket`s.

Deliberately left out: UDP, Taildrop, Serve, SSH, exit-node switching and any
kind of UI. Anything else in tailscaled's LocalAPI is reachable through
`node.localApi.raw(...)`, without compatibility guarantees.

## Credentials

| Credential | Works with | Notes |
|---|---|---|
| `TailscaleCredential.authKey(key)` | Tailscale auth keys, Headscale pre-auth keys | Reusable, ephemeral and tags are properties of the key. |
| `TailscaleCredential.oauthClient(...)` | Tailscale only | Mints a short-lived tagged auth key through the Tailscale API before starting. |
| `TailscaleCredential.existingState()` | both | Reuses the node key in `stateDir`; throws `TailscaleAuthRequiredException` if a login is needed. |
| `TailscaleCredential.interactive()` | both | Publishes the login URL on `node.authUrls`; your app decides what to do with it. |

## Headscale

Point `controlUrl` at the Headscale base URL; nothing else changes. Headscale
has no OAuth client API (use pre-auth keys), issues no TLS certificates and does
not support Funnel or Serve. For interactive logins an admin approves the node
with `headscale auth register --auth-id <id from the URL> --user <user>`.

An unreachable or wrong control URL produces no error; the node just stays in
`Starting` or `NeedsLogin`. `waitUntilRunning` therefore always takes a timeout
and reports the last state and health messages in its exception.

## Sockets and TLS

* `connect()` returns a `Socks5Socket`, a real `dart:io` `Socket` tunnelled
  through the node's loopback SOCKS5 proxy. For TLS use `socket.secure(...)` or
  `node.connectSecure()`, not `SecureSocket.secure`.
* `httpClient()` returns an `HttpClient` whose connections go over the tailnet,
  so `package:http`, `dio`, gRPC and `WebSocket.connect(customClient:)` work
  unchanged.
* `listen()` and `dial()` use libtailscale's file-descriptor path and yield
  `TailscaleSocket` (a `Stream<Uint8List>` plus an `IOSink`). TLS is not
  available on that path.

Nothing blocks the calling isolate: blocking calls run on helper isolates, and a
dedicated isolate drives every file descriptor with one `poll(2)` loop.

## Build configuration

The pub package contains no binaries. A build hook provides the native library
when the app is built, trying these in order:

1. `prebuilt_dir`: a directory you supply containing `libtailscale.{dylib,so}`
   or the architecture-specific `libtailscale-<os>-<arch>[-<sdk>].<ext>`.
2. `build_from_source`: `go build` from a pinned upstream checkout. Needs Go
   (the hook selects the version upstream builds with through `GOTOOLCHAIN`)
   and the NDK or Xcode for mobile targets.
3. Download of the prebuilt library from this repository's GitHub release,
   verified against the SHA-256 pinned in the package.

Option 3 is the default and needs no configuration, only network access to
github.com at build time. To use one of the others, add to the
**application's** `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    libtailscale:
      build_from_source: true
      # prebuilt_dir: native/libs
      # source_dir: ../libtailscale
      # go: /usr/local/go/bin/go
```

### Android

Minimum API 35; add the `INTERNET` permission. The library is built with 16 KB
page alignment. Two Android quirks are handled for you: apps may not list
network interfaces through netlink, so the library ships its own interface
getter, and app processes have no `$HOME` or `$TMPDIR`, so `start()` points
both at the state directory.

### iOS

Minimum iOS 15. Flutter bundles the library as `tailscale.framework`. Set
`NSLocalNetworkUsageDescription` (peers on the same LAN are reached directly)
and ship a privacy manifest; the one in `examples/node_console/ios/Runner`
declares the API categories the Go runtime and tsnet use. WireGuard stops while
the app is suspended; if the loopback listener is stale afterwards, `status()`
falls back to the C status call and `dial()` keeps working.

### Linux

Built on Ubuntu 24.04; requires glibc 2.39 or newer.

### Flutter and Dart SDKs

The hook works with the `hooks` and `code_assets` versions pinned by Flutter
stable as well as the newer releases used with a plain Dart SDK.

## Examples

* [`example/example.dart`](example/example.dart): the whole API in one short
  program.
* [`examples/tsnode/`](examples/tsnode/): a headless command-line node with
  `join`, `info`, `peers`, `echo`, `send` and `fetch`.
* [`examples/node_console/`](examples/node_console/): a Flutter app for macOS,
  iOS, Android and Linux; its README lists the platform settings an embedding
  app needs.

## Known limitations

* UDP is not exposed yet.
* One pipe write end is intentionally leaked per node started with
  `captureLogs: true`, because Go owns that file descriptor.

## Contributing

Development setup, the test suites, cutting a native release and the repository
layout are described in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

BSD-3-Clause, like libtailscale itself.
