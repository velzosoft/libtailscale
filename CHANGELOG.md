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
