# Node Console

A Flutter example for `package:libtailscale`: a **headless** Tailscale /
Headscale node inside a Flutter app, with a UI that only shows what the
library exposes. Runs on macOS, iOS, Android and Linux.

| Screen | Shows / does | Library calls |
|---|---|---|
| **Connect** | Control-server preset (Tailscale, or a Headscale / custom URL), credential (auth key, OAuth client, interactive login, saved state), hostname, ephemeral switch. Connect / Disconnect / Log out. A banner shows the phase, `BackendState`, health warnings and, for interactive logins, the login URL as copyable text. | `TailscaleNode(...)`, `start()`, `waitUntilRunning()`, `stateChanges`, `health`, `authUrls`, `logout()`, `close()` |
| **Node** | Hostname, MagicDNS name, IPv4/IPv6, tailnet and DNS suffix, backend state, control URL, node ID, OS, key expiry, client version, health, certificate domains. Peers (name, IPs, OS, tags, owner, online / relay / last seen), refreshed every 3 s and on pull. | `addresses`, `refreshAddresses()`, `status()` |
| **Communicate** | A chat listener on port 7777 starts as soon as the node runs. Pick a peer, send a line over TCP; incoming lines appear with the sender resolved through `whoIs`. An HTTP field fetches any tailnet URL and shows status, headers and body size. | `listen(port: 7777)`, `connect(host, port)`, `whoIs(ip)`, `httpClient()` |

All lifecycle logic lives in [`lib/src/node_controller.dart`](lib/src/node_controller.dart);
the chat protocol in [`lib/src/chat_service.dart`](lib/src/chat_service.dart) is
one UTF-8 line per message with the line echoed back, so `tsnode echo` and
`tsnode send` from [`../tsnode`](../tsnode) are valid counterparts.
The widgets contain no networking code.

## Run

The library is built from the pinned upstream Go sources by the package's
build hook (`hooks.user_defines.libtailscale.build_from_source: true` in
`pubspec.yaml`), so a Go toolchain (>= 1.25.5) must be on `PATH`. The first
build of each target takes a few minutes; later builds hit Go's cache.

```sh
cd examples/node_console
flutter pub get
flutter run -d macos
flutter run -d <iphone simulator or device>   # Xcode
flutter run -d <android device or emulator>    # Android SDK + NDK
flutter build linux                            # on Linux, glibc >= 2.39
```

Prefill the Connect form (and optionally connect on launch) with
`--dart-define`s, e.g. for a device checklist against Headscale:

```sh
flutter run -d <device> \
  --dart-define=NODE_CONSOLE_CONTROL_URL=https://hs.example.com \
  --dart-define=NODE_CONSOLE_AUTH_KEY=<pre-auth key> \
  --dart-define=NODE_CONSOLE_HOSTNAME=phone-a \
  --dart-define=NODE_CONSOLE_AUTOCONNECT=true
```

Other keys: `NODE_CONSOLE_OAUTH_CLIENT_ID`, `NODE_CONSOLE_OAUTH_CLIENT_SECRET`,
`NODE_CONSOLE_TAGS`, `NODE_CONSOLE_CREDENTIAL` (`auth_key`, `oauth`,
`interactive`, `existing`), `NODE_CONSOLE_EPHEMERAL`. Lifecycle transitions
are written to the debug log as `node-console: phase=… state=…`.

### Without an account

Run the package's in-process test control server from the repository root and
point the app at it with the interactive credential; the test server approves
every node by itself. The iOS simulator and the macOS app reach the Mac's
loopback directly.

```sh
echo '{"build_from_source": true, "build_test_control": true}' > hook/local_config.json
dart run tool/test_control_server.dart        # prints http://127.0.0.1:<port>
(cd examples/tsnode && dart run bin/tsnode.dart echo --control-url $URL --interactive --hostname echo-a --state-dir /tmp/a)
```

Then, in the app: Headscale / URL preset with that URL, method "Interactive
login", Connect. On the Communicate screen pick `echo-a` and send a line; the
echo marks it delivered. `tsnode send <app ip> 7777 hi` works the other way.

## Platform notes

Everything below is what an application embedding libtailscale needs; the
library itself has no platform code.

* **macOS**: the sandboxed app needs `com.apple.security.network.client` (and
  `network.server` for listeners) in both entitlement files. Deployment target
  15.0.
* **iOS**: deployment target 15.0. `NSLocalNetworkUsageDescription` is set
  because peers on the same LAN are reached directly. `Runner/PrivacyInfo.xcprivacy`
  declares the file-timestamp and system-boot-time API categories the Go
  runtime and tsnet use; treat it as a starting point for your own manifest.
  Userspace WireGuard stops while the app is suspended: on resume the app
  refreshes status and restarts the chat listener if it closed.
* **Android**: `minSdk = 35`, the `INTERNET` permission. The library is linked
  with 16 KB page alignment.
* **Linux**: nothing special; glibc >= 2.39.

The state directory is `<application support>/libtailscale/<hostname>`; only
the node key lives there, no form values or secrets are persisted.

## Device checklist (plan §6.3)

1. Join Tailscale with an auth key; join Headscale with a pre-auth key; join
   Tailscale with an OAuth client.
2. Node screen matches `tailscale status` / the Headscale admin view.
3. Chat device ↔ device and device ↔ `tsnode echo`, both directions, also
   after backgrounding and resuming.
4. HTTP fetch reaches a peer's HTTP service by MagicDNS name.
