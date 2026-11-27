## 1.2.0

* Built on tailscale.com v1.104.1 (was v1.94.1), from upstream libtailscale
  `dacde75`. The prebuilt libraries come from the `native-v0.2.0` release.
* Upstream fixes that reach this package:
  * A `TailscaleSocket` accepted by `TailscaleServerSocket` could report
    another peer's `remoteAddress` when file descriptor numbers were reused.
  * Listener and connection file descriptors are close-on-exec, so a
    `Process` started by the app no longer keeps them open (and delays EOF
    on close).
  * Closing a connection could shut down an unrelated, reused descriptor.
* Source builds (`build_from_source`) need Go 1.27.1. The hook still selects
  that version through `GOTOOLCHAIN`, so any Go that can switch toolchains
  works.
* Source builds rerun when any of upstream's Go or C files change, not only
  `tailscale.go`, `tailscale.c` and `go.mod`.

## 1.1.1

* The build hook no longer reports deprecation notices with `code_assets`
  2.2.0, the version Flutter 3.50 resolves.
* No behaviour changes.

## 1.1.0

* New `skip_unsupported_targets` user-define: an app that never uses
  libtailscale on a platform it does not support, such as Windows, can now
  build for that platform. The hook bundles nothing for it
  ([#1](https://github.com/velzosoft/libtailscale/issues/1)).
* Without the option, the build error for an unsupported platform now names
  it.
* `TailscaleNode.start()` throws `TailscaleUnsupportedException` at once on an
  unsupported platform, instead of failing later with an FFI symbol-lookup
  error.

## 1.0.1

* README rewritten for package users: quick start, coverage, credentials,
  Headscale, sockets, build configuration and platform notes. Development and
  release instructions moved to `CONTRIBUTING.md`.
* No code changes.

## 1.0.0

Initial release.

* `TailscaleNode`: `start`, `waitUntilRunning`, `logout`, `close`; state,
  health, login-URL and log streams.
* Credentials: auth / pre-auth key, Tailscale OAuth client, existing state,
  interactive login. Works with Tailscale and Headscale control servers.
* Observation: `addresses`, `status()` with peers and users, `whoIs`.
* Operation: `connect` / `connectSecure` / `httpClient` over the loopback
  SOCKS5 proxy; `listen` / `dial` over libtailscale file descriptors.
* Build hook: `prebuilt_dir`, `build_from_source` (macOS, iOS, Android,
  Linux) or a checksum-verified download of the prebuilt library.
* Platforms: macOS 15+, iOS 15+, Android 15+ (API 35), Linux glibc 2.39+.
* Examples: `example/example.dart`, the `tsnode` CLI and the `node_console`
  Flutter app (`examples/`, repository only).
