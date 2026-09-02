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
