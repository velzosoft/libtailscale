# Plan: a Dart / Flutter Tailscale client on top of libtailscale (dart:ffi)

| | |
|---|---|
| Status | Draft v1, research complete |
| Date | 2026-09-02 |
| Package name | `libtailscale` (decided 2026-09-02; confirmed available on pub.dev) |
| Upstream | https://github.com/tailscale/libtailscale @ `main` (last commit 2026-08-30), `tailscale.com v1.94.1`, `go 1.25.5`, BSD-3-Clause |
| Targets (v1) | macOS, Linux, iOS, Android. Windows deferred (blocked upstream, see §4.6) |
| Control servers | Tailscale (`https://controlplane.tailscale.com`) and Headscale (any base URL) |
| Nature | **Headless library**: no UI, no browser launching, no platform channels. The host app supplies a control URL and a credential. The only UI in the repository is the example app (§6). |

---

## 1. Goal and scope

Build and publish a **headless** Dart package that embeds a userspace Tailscale node into any Dart or Flutter application through `dart:ffi` bindings to the official libtailscale C library. The host application supplies a control-server URL and a credential; the library joins the tailnet and exposes just enough to **control** the node and **operate** over it. It renders nothing, opens no browser, and has no platform channels.

**Design principle: minimal operating surface, not API parity.** libtailscale and LocalAPI expose far more than an embedding app needs. Bindings are generated for the whole C header (that is free), but only the surface below is designed, documented, tested and supported. Everything else stays internal or is omitted.

| Area | Included in v1 | Deliberately excluded |
|---|---|---|
| Configure | control URL (Tailscale or Headscale); credential: auth / pre-auth key, or Tailscale OAuth client id + secret (exchanged for a key by the library); hostname; state directory; ephemeral flag | web client, WireGuard port selection, custom stores (need upstream setters) |
| Control | `start()`, `waitUntilRunning(timeout)`, `close()`, `logout()`, `state` stream, `health` stream, optional `authUrls` stream (plain string, for apps that opt into interactive login) | any UI, browser launching, QR codes, login pages |
| Observe | addresses (IPv4/IPv6), MagicDNS name, `status()` with peers (name, IPs, online, tags, OS), `whoIs(ip)` | metrics, bug reports, DERP map, profiles, prefs editing beyond hostname/tags |
| Operate | `connect(host, port)` → `dart:io Socket`, `httpClient()`, `listen(port)` / accept → `TailscaleSocket`, half-close | UDP (v1.1 via SOCKS5 UDP ASSOCIATE), Taildrop, Funnel, Serve, `cert`, SSH, exit-node switching |
| Platforms | macOS 15+, iOS 15+, Android 15+ (API 35, Vanilla Ice Cream), Linux distributions released 2024 or later (glibc 2.39+, e.g. Ubuntu 24.04, Fedora 40) | Windows (upstream blocker), web |

Everything excluded stays reachable for advanced users through `node.localApi.raw(...)`, an authenticated HTTP escape hatch with no support guarantees.

---

## 2. What libtailscale actually provides (verified from source)

### 2.1 Repository facts

- A Go `package main` (`tailscale.go`) exporting `Tsnet*` functions via `//export`, a thin C wrapper (`tailscale.c`) exposing the public `tailscale_*` API, and the header `tailscale.h`. Building with `go build -buildmode=c-archive` or `c-shared` produces a library containing **both** symbol sets (cgo compiles `tailscale.c` as part of the package).
- No GitHub releases and no prebuilt binaries. Everyone builds from source with Go ≥ 1.25.5 (module `go` directive), CGO enabled.
- Existing bindings in-tree: Swift (`TailscaleKit`, actor-based, uses `poll(2)` + `read/write` on the fds), Python (pybind11), Ruby (Ruby-FFI, wraps fds with `IO.for_fd`). These are the reference for our FFI design.
- **Unix-only**: `tailscale.go` imports `golang.org/x/sys/unix` and uses `syscall.Socketpair`, `Sendmsg` + `UnixRights`, `Recvmsg`. It does not compile for `GOOS=windows`. A Windows port (PR #25, Jan 2024, emulated socketpair in C) is unmerged.
- Test utilities: `tsnetctest` (C test driven from Go) and `tstestcontrol` (a c-archive exposing `RunControl`/`StopControl`: an in-process Tailscale control server + DERP + STUN on 127.0.0.1). The latter is directly reusable for our hermetic integration tests.
- Build files: root `Makefile` (c-shared, c-archive, iOS device/simulator archives via `swift/script/clangwrap-ios*.sh`, `MACOS_TARGET ?= 15.0` which only matters for the Swift wrapper), `sourcepkg/Makefile.src` (adds `-trimpath -buildvcs=false`, a `lipo` universal dylib recipe, and a `.pc` file).
- Open upstream PRs worth tracking: #59 universal macOS slice, #57 App Store distribution (missing `PrivacyInfo.xcprivacy` causes ITMS-91053 rejection), #55 SwiftPM + Linux, #25 Windows.

### 2.2 The C API, with the semantics that matter for a binding

All handles are plain `int`s. Return convention: `0` success, `-1` "see `tailscale_errmsg`", or a positive errno (`EBADF` = bad handle, `ERANGE` = buffer too small; output buffers are always NUL-terminated). Passing a NULL buffer or zero length **panics the Go runtime** (process abort), so the Dart layer must never do that.

| Function | Blocks? | Notes from `tailscale.go` |
|---|---|---|
| `tailscale_new()` | no | Returns a handle (first is `42<<16 + 1`). Cannot fail. Sets `hostinfo` app name to `libtailscale`. Several nodes per process are fine. |
| `tailscale_set_dir / _hostname / _authkey / _control_url / _ephemeral` | no | Plain field setters on `tsnet.Server`; must be called before start. No validation. Empty control URL → `TS_CONTROL_URL` env → Tailscale default. Empty auth key → `TS_AUTHKEY` env. Empty dir → `$UserConfigDir/tsnet-<exe basename>` (on iOS the exe name falls back to `tsnet`). Empty hostname → executable basename (`Runner`, `dart`…), so always set it. An OAuth client secret (`tskey-client-…`) given as the auth key is rejected by tsnet (`oauth authkeys require --advertise-tags`) because the C API cannot set `AdvertiseTags`; the Dart layer exchanges OAuth credentials for a real auth key itself (§3.9). |
| `tailscale_set_logfd(fd)` | no | `-1` discards logs. Otherwise Go wraps the fd with `os.NewFile` and writes **`tsnet.Server.Logf`** (verbose backend logs) to it. It does *not* set `UserLogf`; the interactive login line `To start this tsnet server, restart with TS_AUTHKEY set, or go to: <url>` is emitted through `UserLogf`/`log.Printf` (stderr), so the auth URL **cannot** be captured from this fd. Use status JSON or the IPN bus instead (§3.9). |
| `tailscale_start()` | short, but does I/O | Creates state dir, engine, netmon, backend; returns quickly but is not free (100s of ms). Run off the UI isolate. |
| `tailscale_up()` | **yes, until `Running`** | Watches the IPN bus with `context.Background()`; **not cancellable** (`TsnetClose` has a `// TODO: cancel Up`). Returns `-1` on backend `ErrMessage`. First successful `Up` also clears any persisted serve config. Our API will avoid it (§3.9). |
| `tailscale_close()` | short | Removes the handle and calls `Server.Close()` if started. Does **not** close listeners/conns or cancel `Up` (TODOs in source). Dart must track and close every fd itself. |
| `tailscale_getips(buf)` | no | `"<ip4>,<ip6>"`. Before the node is running the values are the zero `netip.Addr`, rendered as `invalid IP`; parse defensively. |
| `tailscale_dial(net, addr, &fd)` | **yes** (network dial) | `net` = `tcp`/`udp`, `addr` = `host:port` (MagicDNS names resolve). Returns one end of an `AF_LOCAL, SOCK_STREAM` socketpair; two goroutines copy bytes both ways with 64 KiB buffers and propagate half-close via `shutdown`. Implicitly starts the server. **UDP caveat**: datagram boundaries are lost because the socketpair is a stream. |
| `tailscale_listen(net, addr, &ln)` | no | `addr` must be `host:port` (`":8080"` is fine). Returns a socketpair end that becomes **readable when a connection is queued** (explicitly designed for `poll`/`epoll`). Closing the fd is the only way to stop the listener (Go notices EOF and tears down). Implicitly starts the server. |
| `tailscale_accept(ln, &fd)` | **yes** unless polled | `recvmsg` receives the connection fd via `SCM_RIGHTS`. Poll `ln` for `POLLIN` first to make it non-blocking. |
| `tailscale_getremoteaddr(ln, fd, buf)` | no | Remote **IP only** (port stripped), valid while the listener is alive. |
| `tailscale_loopback(&addr, proxy[33], local[33])` | short (calls start) | Once per server starts `127.0.0.1:<random>` and returns `"127.0.0.1:port"` plus two 32-hex credentials. The same port serves **SOCKS5** (username `tsnet`, password = proxy cred; CONNECT and UDP ASSOCIATE are implemented in `tailscale.com/net/socks5`) and **LocalAPI over HTTP** (requires header `Sec-Tailscale: localapi` and Basic auth with empty username and the local cred as password; `PermitWrite` is true). There is **no HTTP CONNECT proxy** (tsnet TODO). The address is cached forever; upstream notes iOS may reclaim the listener while the process is suspended, leaving the address stale. |
| `tailscale_status_json(&cstr)` | up to 10 s | In-memory LocalAPI `Status` (no TCP), returns a `malloc`'d JSON string that the caller must `free()`. Safe on iOS after suspend. Added 2026-06. |
| `tailscale_enable_funnel_to_localhost_plaintext_http1(port)` | yes | Reads `CertDomains[0]` **without a bounds check**: on Headscale (no cert domains) this is a Go panic → process crash. Must be gated in Dart. Tailscale-only. |
| `tailscale_errmsg(buf)` | no | Last error for that server (cleared by the next successful call). |

Not exposed by the C API but present in `tsnet.Server`: `Port`, `AdvertiseTags`, `Store` (in-memory store for ephemeral nodes), `RunWebClient`, OAuth `ClientID/ClientSecret`, `ListenTLS`, `ListenFunnel`, `ListenPacket`, `HTTPClient`, `CapturePcap`. Some are reachable via LocalAPI prefs; the rest need upstream additions (§10).

### 2.3 LocalAPI reachable through the loopback listener

Everything `tailscale.com/client/local` can do is available over plain HTTP from Dart. The subset we will use:

| Endpoint | Method | Use |
|---|---|---|
| `/localapi/v0/status` (`?peers=false`) | GET | Full `ipnstate.Status` JSON (peers, self, health, cert domains, MagicDNS suffix). Same document as `tailscale_status_json`. |
| `/localapi/v0/watch-ipn-bus?mask=N` | GET (streaming NDJSON) | `ipn.Notify` events: `State`, `BrowseToURL`, `LoginFinished`, `ErrMessage`, `NetMap`, `Health`. Mask bits: 1 engine updates, 2 initial state, 4 initial prefs, 8 initial netmap, 16 no private keys, 32 initial health, 64 rate limit. `State` ints: 0 NoState, 1 InUseOtherUser, 2 NeedsLogin, 3 NeedsMachineAuth, 4 Stopped, 5 Starting, 6 Running. |
| `/localapi/v0/login-interactive` | POST → 204 | Forces generation of an auth URL when in `NeedsLogin`. |
| `/localapi/v0/logout` | POST → 204 | Log out (node key deleted). |
| `/localapi/v0/prefs` | GET / PATCH (`MaskedPrefs`) | Hostname, `AdvertiseTags`, exit node, `WantRunning`, etc. |
| `/localapi/v0/whois?addr=` | GET | Identity of a peer IP or `ip:port`. |
| `/localapi/v0/ping?ip=&type=` | POST | Disco/TSMP/ICMP ping. |
| `/localapi/v0/dns-query`, `/derpmap`, `/metrics`, `/bugreport`, `/set-expiry-sooner`, `/query-feature` | | Diagnostics and utilities. |
| `/localapi/v0/file-put/`, `/files/`, `/file-targets` | | Taildrop (later milestone). |
| `/localapi/v0/cert/<domain>`, `/serve-config`, `/id-token` | | Tailscale-only (no Headscale support). |
| `/localapi/v0/dial` | POST + `Upgrade: ts-dial` | Alternative TCP dial path over HTTP upgrade; we prefer SOCKS5. |

Status JSON keys are Go field names (`BackendState`, `AuthURL`, `TailscaleIPs`, `Self`, `Peer`, `User`, `CurrentTailnet`, `CertDomains`, `Health`, `MagicDNSSuffix`, `ClientVersion`). `PeerStatus` includes `ID`, `PublicKey`, `HostName`, `DNSName`, `OS`, `UserID`, `TailscaleIPs`, `AllowedIPs`, `Tags`, `Online`, `Active`, `Expired`, `LastSeen`, `LastHandshake`, `RxBytes`, `TxBytes`, `Relay`, `CurAddr`, `ExitNode`, `CapMap`.

### 2.4 Headscale compatibility

- libtailscale is `tsnet`, so pointing `tailscale_set_control_url` at the Headscale base URL (e.g. `https://hs.example.com`, plain `http://` accepted for labs) is all that is needed. Nothing else in the C API is Tailscale-specific.
- **Registration**: pre-auth keys (`headscale preauthkeys create --user <u> [--reusable] [--ephemeral] [--tags tag:x]`) via `tailscale_set_authkey`; or interactive: the node enters `NeedsLogin`, an auth URL is published (`BrowseToURL` / `Status.AuthURL`); on Headscale the URL carries a registration id that an admin passes to `headscale auth register --auth-id <id> --user <u>` (Headscale ≥ 0.29; older versions: `headscale nodes register --user <u> --key mkey:…`), or an OIDC login if configured. Afterwards the state moves to `Running` without restarting.
- Supported by Headscale (per its feature matrix): MagicDNS, split DNS, embedded DERP, ephemeral nodes, tags, ACLs/grants, Tailscale SSH, Taildrop/Taildrive, subnet routers, exit nodes, OIDC. **Not supported**: Funnel, Serve, network flow logs. Consequences for us: gate `tailscale_enable_funnel_*` (crash risk), expect `CertDomains` to be empty and `cert/` calls to fail, and serve TLS with your own certificates if needed.
- Known tsnet behaviour (tailscale#16201): an unreachable or non-Tailscale control URL produces no error; the node just stays in `Starting`/`NeedsLogin`. Our API must expose timeouts and `Health` messages so apps can diagnose a wrong Headscale URL.
- Version skew: Headscale validates client versions. We pin `tailscale.com` (currently 1.94.1) and run CI against the current Headscale stable.

---

## 3. Dart FFI design

### 3.1 Layering

```
┌──────────────────────────────────────────────────────────────────────┐
│ Public API   TailscaleNode · TailscaleServerSocket · TailscaleSocket  │
│              node.httpClient() · node.status() · node.localApi        │
├──────────────────────────────────────────────────────────────────────┤
│ Runtime      NodeStateMachine (IPN bus / status polling)              │
│              NativeWorker (Isolate.run for blocking C calls)          │
│              FdReactor (poll(2) loop isolate for listener/conn fds)   │
│              Socks5Client (pure Dart, over loopback)                  │
│              LocalApiClient (dart:io HttpClient, NDJSON stream)       │
├──────────────────────────────────────────────────────────────────────┤
│ Bindings     lib/src/ffi/tailscale_bindings.g.dart  (ffigen, @Native)│
│              lib/src/ffi/libc.dart (read/write/close/poll/pipe/errno) │
├──────────────────────────────────────────────────────────────────────┤
│ Native       libtailscale.{dylib,so}  (Go c-shared / c-archive→dylib) │
│              delivered by hook/build.dart (download+verify or go build)│
└──────────────────────────────────────────────────────────────────────┘
```

Design rule: **every C call that can block or do I/O runs off the caller's isolate**; the public API is fully async and never blocks the Flutter UI thread.

### 3.2 Native asset: one code asset per platform

`hook/build.dart` registers a single `CodeAsset` named `package:libtailscale/src/ffi/tailscale_bindings.g.dart` with `DynamicLoadingBundled()`. Per Flutter's rules the file name must be identical across architectures and SDKs (Flutter `lipo`s per-arch outputs and builds the XCFramework itself):

| Target OS | File produced by the hook | Built with |
|---|---|---|
| macOS (arm64, x64) | `libtailscale.dylib` | `GOOS=darwin GOARCH=… go build -buildmode=c-shared` (Go supports c-shared on darwin). `-mmacos-version-min=15.0` (Sequoia; decided, and the same as upstream's `MACOS_TARGET` default). |
| Linux (x64, arm64) | `libtailscale.so` | `go build -buildmode=c-shared` on the Ubuntu 24.04 baseline (glibc 2.39; decided: no distribution older than 2024, so Debian 12 and RHEL 9 are out of scope). |
| Android (arm64-v8a, x86_64, optional armeabi-v7a) | `libtailscale.so` | `GOOS=android CC=<ndk>/aarch64-linux-android35-clang go build -buildmode=c-shared` with `CGO_LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-soname,libtailscale.so"` (Google Play 16 KB page requirement). API level comes from `input.config.code.android.targetNdkApi`. |
| iOS device (arm64) and simulator (arm64, x64) | `libtailscale.dylib` | Go's `c-shared` mode is **not** supported for `GOOS=ios` (only `c-archive`). So: `GOOS=ios GOARCH=arm64 CC=clangwrap-ios.sh go build -buildmode=c-archive -tags ios -ldflags -w`, then `clang -dynamiclib -arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=15.0 -Wl,-all_load libtailscale.a -framework CoreFoundation -framework Security -lresolv -install_name @rpath/libtailscale.framework/libtailscale -o libtailscale.dylib`. SDK selection from `input.config.code.iOS.targetSdk`. Our own clang wrapper pins `-mios-version-min=15.0` (upstream's `clangwrap-ios*.sh` use 12.0). |

Both `tailscale_*` and `Tsnet*` symbols are exported; ffigen binds only `tailscale_*` from `tailscale.h`.

### 3.3 Bindings generation

- `ffigen` 21 (Dart-API config in `tool/ffigen.dart`), `ffiNative: FfiNative(assetId: 'package:libtailscale/src/ffi/tailscale_bindings.g.dart')`, `functions: Functions.includeSet({...tailscale_*})`, entry point `third_party/libtailscale/tailscale.h`. Generated `@Native<Int Function(...)>` externals; regenerate only when the header changes and commit the output (consumers never need libclang).
- libc bindings (`lib/src/ffi/libc.dart`) are hand-written `@Native` declarations resolved with a second `CodeAsset(linkMode: LookupInProcess())` (the `host_name` pattern from the Dart docs): `read`, `write`, `close`, `shutdown`, `poll`, `pipe`, `fcntl`, `free`, and errno via `__error()` (Apple) / `__errno_location()` (Linux/Android). This avoids shipping a C shim in v1; a shim (kqueue/epoll thread + `NativeCallable.listener`) remains an optional optimisation.

### 3.4 Calling conventions and memory

- Strings: `package:ffi` `toNativeUtf8()` into `calloc`, freed in `finally`.
- Out buffers: `errmsg` 1024 B, `getips` 128 B, `loopback` addr 64 B + two 33 B cred buffers, `getremoteaddr` 64 B; on `ERANGE` retry once with a larger buffer.
- `tailscale_status_json` returns a `malloc`'d pointer: copy to a Dart `String` and call libc `free`.
- Errors → `TailscaleException(code, message)` where `message` is fetched with `tailscale_errmsg` for `-1`, `strerror`-style text for errno codes, plus `TailscaleClosedException` for use-after-close.
- Handles and fds are ints and therefore safe to send between isolates; the wrapper objects are not.

### 3.5 Blocking calls and isolates

`NativeWorker` runs `tailscale_start`, `tailscale_dial`, `tailscale_loopback`, `tailscale_status_json` and (if ever used) `tailscale_up` via `Isolate.run`. Rationale: Go blocks the calling OS thread; a blocked helper isolate is harmless, a blocked main isolate freezes Flutter. Because `tailscale_up` cannot be cancelled, the public API implements "wait until running" in Dart (§3.9) instead of calling it; it stays available as `node.upBlocking()` for CLI use with a clear warning.

### 3.6 Fd I/O engine (`FdReactor`)

One dedicated isolate per node running a `poll(2)` loop over: the wake pipe, every listener fd (`POLLIN` = connection queued), and every connection fd (`POLLIN`, and `POLLOUT` only while a write is pending).

- Connection fds are switched to `O_NONBLOCK`. Reads: up to 64 KiB into a reusable native buffer, delivered to the owner isolate as `TransferableTypedData`. Writes: attempted inline; `EAGAIN` queues the remainder and arms `POLLOUT` (backpressure surfaces as an `IOSink`-style `Future<void> flush()`).
- Listener readiness triggers `tailscale_accept` (now non-blocking) + `tailscale_getremoteaddr`; the new fd is registered and a `TailscaleSocket` is emitted on the server socket's stream.
- Close semantics mirror upstream: `close(2)` on a conn fd makes Go close the tailnet connection; `close(2)` on the listener fd stops the listener; `shutdown(SHUT_WR)` gives a clean half-close. `TailscaleNode.close()` closes every tracked fd **before** `tailscale_close` because Go does not.
- Wake-up for registration changes uses the classic self-pipe.
- `TailscaleSocket` implements `Stream<Uint8List>` + `IOSink`; it is intentionally not a `dart:io Socket` (no public fd constructor exists in Dart).

### 3.7 Outbound TCP without fds: SOCKS5 over loopback

For outbound TCP the loopback SOCKS5 proxy is the better primitive because it yields a **real `dart:io Socket`**:

1. `Socket.connect('127.0.0.1', port)` → RFC 1928 greeting with method 0x02 → RFC 1929 username/password (`tsnet` / proxy cred) → `CONNECT` to `host:port` (domain address type lets tsnet resolve MagicDNS names).
2. Hand the socket to callers as `Socket`; wrap with `SecureSocket.secure(socket, host: …)` for TLS.
3. `node.httpClient()` returns an `HttpClient` whose `connectionFactory = (uri, proxyHost, proxyPort) async => ConnectionTask.fromSocket(socks5Connect(uri), cancel)` and `findProxy = (_) => 'DIRECT'`, so `package:http`, `dio` (IO adapter), gRPC and `WebSocket.connect(customClient:)` all work over the tailnet unchanged.
4. UDP: SOCKS5 `UDP ASSOCIATE` preserves datagram boundaries (the fd path does not), implemented with `RawDatagramSocket` + the SOCKS UDP header. Milestone 4.
5. iOS caveat: because upstream reports the loopback listener can go stale after suspension, iOS defaults to the fd dial path (`tailscale_dial` via `NativeWorker`) and re-probes loopback on resume; desktop and Android default to SOCKS5.

### 3.8 LocalAPI client

`LocalApiClient` (dart:io `HttpClient`, base `http://127.0.0.1:port`, headers `Sec-Tailscale: localapi` and `Authorization: Basic base64(":" + cred)`), typed wrappers only for what the v1 surface needs (`status`, `whois`, `logout`, `login-interactive`, and `watch-ipn-bus` as `Stream<IpnNotify>` over NDJSON) plus `raw(method, path, {body})` as an unsupported escape hatch for everything else in §2.3. Models (`Status`, `PeerStatus`, `TailnetStatus`, `UserProfile`, `IpnNotify`, `Prefs`, `MaskedPrefs`) are hand-written immutable classes with `fromJson`; unknown keys are ignored so tailscale upgrades do not break parsing.

### 3.9 Credentials, node state and authentication (headless)

The host app provides `controlUrl` and exactly one `TailscaleCredential`:

| Credential | Works with | How the library uses it |
|---|---|---|
| `TailscaleCredential.authKey(key)` | Tailscale auth keys (`tskey-auth-…`), Headscale pre-auth keys | Passed straight to `tailscale_set_authkey`. Reusable / ephemeral / tags are properties of the key, decided when it was created. |
| `TailscaleCredential.oauthClient(id, secret, tags: [...], ephemeral: true, preauthorized: true)` | Tailscale only (Headscale has no OAuth) | The library does the exchange itself in Dart before `start()`: `POST {api}/api/v2/oauth/token` (client credentials) then `POST /api/v2/tailnet/-/keys` to mint a single-use auth key carrying the tags, then sets it. tsnet's built-in OAuth path is unusable through libtailscale because it requires `AdvertiseTags`, which the C API cannot set. |
| `TailscaleCredential.existingState()` | both | No credential. Relies on the node key already persisted in `stateDir` by an earlier run. If it expired, the node lands in `NeedsLogin` and `waitUntilRunning` fails with `TailscaleAuthRequired`. |
| `TailscaleCredential.interactive()` (opt-in) | both | No key. The library only publishes the login URL string on `node.authUrls`; what the app does with it (log it, hand it to an admin, display it) is the app's business. On Headscale an admin approves it with `headscale auth register --auth-id <id> --user <u>` (`nodes register --key` before 0.29). |

Workload identity federation (`ClientID` + `IDToken`/`Audience`) is Tailscale-only and needs fields the C API lacks; it is out of scope.

```
configure ──start()──▶ Starting ──▶ NeedsLogin ──(credential accepted | URL completed)──▶ Running
                                   │                                                    ▲
                                   └─ NeedsMachineAuth (admin approval on control) ─────┘
close() → Stopped   ·   InUseOtherUser / ErrMessage / timeout → TailscaleException
```

- `start()` runs `tailscale_start` on the worker, opens the loopback LocalAPI and subscribes to `watch-ipn-bus?mask=2|32` (initial state + health). `node.state` is a broadcast `Stream<BackendState>` with a current value; `node.health` carries health strings; `node.authUrls` exists only for the interactive credential.
- `waitUntilRunning({timeout})` completes when the bus reports `Running` and `tailscale_getips` yields valid IPs (the same condition as `tsnet.Up`), without calling the uncancellable `tailscale_up`. It fails fast on `ErrMessage`, on `InUseOtherUser`, and on timeout, attaching the last health messages so a wrong Headscale URL or an expired key is diagnosable from logs alone.
- Fallback when loopback is unavailable (iOS after suspend): poll `tailscale_status_json` every 1–2 s for `BackendState`.
- `logout()` posts `logout` (drops the node key); `close()` closes every fd first, then `tailscale_close`.
- The library never scrapes stderr for the auth URL; tsnet prints it via `UserLogf`, which the C API does not expose.

### 3.10 Public API sketch (headless)

```dart
final node = TailscaleNode(TailscaleConfig(
  controlUrl: 'https://headscale.example.com',          // omit for Tailscale
  credential: TailscaleCredential.authKey(preAuthKey),   // or .oauthClient(id, secret, tags: [...])
  hostname: 'inventory-agent',
  stateDir: stateDirectory,                               // always set; required on iOS
  ephemeral: true,
));

await node.start();
await node.waitUntilRunning(timeout: const Duration(seconds: 60));
final addrs = node.addresses;                             // TailscaleAddresses(ipv4, ipv6)

final server = await node.listen(port: 8080);            // Stream<TailscaleSocket>
server.listen((c) => c.pipe(c));                          // echo service on the tailnet

final sock = await node.connect('files.example.ts.net', 443); // dart:io Socket via SOCKS5
final http = node.httpClient();                           // HttpClient routed over the tailnet
final peers = (await node.status()).peers;                // name, ips, online, tags, os

node.state.listen((s) => log('tailscale: $s'));          // observation only, no UI
await node.close();
```

### 3.11 Logging

`tailscale_set_logfd` receives the write end of a `pipe(2)` created via libc; the reactor drains the read end into `node.logs` (`Stream<String>`, line-split). Default is `-1` (discard) unless the app opts in, because backend logs are verbose.

### 3.12 Go runtime inside the Dart VM

Loading the library starts the Go runtime (its own threads, `SIGURG` preemption signals, `SIGPROF` handling). Go's c-shared runtime is designed to coexist with host signal handlers and Flutter apps embedding Go via FFI are common on POSIX; the M0 spike explicitly verifies: hot restart / re-`dlopen` behaviour, `GOMAXPROCS` footprint, memory (expect roughly 30–50 MB library on disk, tens of MB RSS), and iOS background suspension. Known Windows crash reports with Go DLLs inside the Dart VM are one more reason Windows is deferred.

---

## 4. Build, packaging and distribution

### 4.1 Consumer experience

`dart pub add libtailscale` (or Flutter) → first `dart run` / `flutter build` invokes `hook/build.dart`, which downloads the prebuilt native library for the exact target from our GitHub release, verifies its SHA-256 against hashes committed in the package, and registers it as a code asset. No Go, no C toolchain needed. `hooks.user_defines` lets an app opt into `build_from_source: true` (requires Go ≥ 1.25.5 and, for mobile, the SDK/NDK exposed by `input.config.code.cCompiler`) or `prebuilt_dir: <path>` for air-gapped builds.

SDK constraints: Dart `^3.10.0` (hooks stable since 3.10), Flutter ≥ 3.38. Local machine today: Dart 3.12.2 / Flutter 3.44.9 (fine), Go not installed (needed for M0).

### 4.2 `hook/build.dart` behaviour

1. Read `targetOS`, `targetArchitecture`, `iOS.targetSdk`, `android.targetNdkApi`, `macOS.targetVersion`.
2. Resolve the artifact key `libtailscale-<os>-<arch>[-<sdk>]` and its pinned hash from `hook/native_manifest.dart` (generated at release time).
3. If `prebuilt_dir` set → copy; else if `build_from_source` → run the Go build recipe from §3.2 (using the compiler from `cCompiler` on Android/iOS); else download into `outputDirectoryShared` (cached across builds), verify hash, copy into `outputDirectory` under the constant file name.
4. Emit the `libtailscale` `CodeAsset` (`DynamicLoadingBundled`) and the libc `CodeAsset` (`LookupInProcess`).
5. Declare `output.dependencies` on the manifest and the recipe files so caching invalidates correctly.

### 4.3 Release pipeline (GitHub Actions, in our repo)

- `native-release.yml`: matrix builds every artifact from a pinned libtailscale commit (git submodule under `third_party/libtailscale`), runs on `macos-15` (darwin arm64/x64, iOS device + simulators, Android via NDK) and `ubuntu-24.04` (linux x64; arm64 either via the native `ubuntu-24.04-arm` runner or an `aarch64-linux-gnu-gcc` cross build). Uploads `*.tar.gz` + `SHA256SUMS` to tag `native-vX.Y.Z` and opens a PR bumping `hook/native_manifest.dart`.
- `ci.yml`: analyze, unit tests, hermetic integration tests (§7), example app builds (macOS, iOS simulator, Android debug APK).
- `publish.yml`: `dart pub publish` on `v*` tags (pub.dev automated publishing).
- Versioning: package semver; native artifacts versioned separately; the package pins one native version. Package tarball stays tiny (well under pub.dev's 100 MB limit) because binaries are downloaded.

### 4.4 iOS specifics

- Flutter wraps the dylib into `libtailscale.framework` and signs it with the app. Minimum iOS 15 (decided 2026-09-02; Go 1.25's floor is 12, so no toolchain constraint is hit).
- App Store: upstream PR #57 found the framework is rejected (ITMS-91053) without a `PrivacyInfo.xcprivacy`; verify whether Flutter's generated framework carries one and, if not, add a link hook or documented step before M3.
- Backgrounding: userspace WireGuard stops when the app is suspended; on resume re-probe loopback, and rely on `tailscale_status_json` (in-memory) for status. No Network Extension entitlement is needed because nothing touches the system network stack.
- Do not call `tailscale_getips` or status before `start()`.

### 4.5 Android specifics

- Minimum Android 15 (API 35, Vanilla Ice Cream; decided 2026-09-02). `INTERNET` permission in the consumer manifest; 16 KB page alignment flags are mandatory at this level, not optional; `soname`. Go/NDK floor is 21, so no toolchain constraint is hit.
- Go on Android uses the NDK's clang; the hook obtains it from `input.config.code.cCompiler` when building from source.

### 4.6 Windows (deferred, blocked upstream)

libtailscale does not compile for Windows (Unix socketpair + `SCM_RIGHTS`). Options, in order of preference: (a) help land upstream PR #25 style support (emulated socketpair over loopback TCP), (b) a Windows-only design that keeps the `tailscale_*` API but implements conns as `WSADuplicateSocket` handles, (c) SOCKS5-only mode (no listeners) once (a) compiles. Track as milestone 5; do not block v1.

### 4.7 Linux specifics

Minimum: distributions released in 2024 or later (decided 2026-09-02), so the glibc-linked c-shared library is built on `ubuntu-24.04` (glibc 2.39) and documented as requiring glibc ≥ 2.39. Optionally add a musl/static variant later for Alpine containers (Go supports `-buildmode=c-shared` on linux with musl via `zig cc`).

---

## 5. Repository layout (package at the root; decided 2026-09-02)

The pub package lives at the repository root, like most single-package Dart repos; everything that is not part of the package is excluded from the pub archive through `.pubignore`.

```
libtailscale/                       # this folder = the pub package
├── lib/libtailscale.dart
├── lib/src/ffi/{tailscale_bindings.g.dart (ffigen output), libc.dart, tailscale_api.dart}
├── lib/src/runtime/{native_worker,fd_reactor,socks5,local_api,ndjson,node_events,oauth_exchange}.dart
├── lib/src/api/{node,config,sockets,status,state,addresses,exceptions}.dart
├── hook/build.dart · lib/src/hook/{native_target,native_manifest,user_config,go_build,artifact_download,resolver}.dart
├── tool/build_native.dart · tool/update_manifest.dart · tool/ffigen/ (separate pubspec: ffigen 21 pins code_assets 1.x)
├── test/{unit,native,integration}/ · test/fixtures/
├── example/example.dart            # single-file example for pub.dev
├── examples/tsnode/                # `tsnode`, headless Dart CLI (§6.1; pub-ignored)
├── examples/node_console/          # Flutter app for macOS, iOS, Android, Linux (§6.2; pub-ignored)
├── third_party/libtailscale/       # git submodule pinned to a commit (pub-ignored)
├── specs/                          # this plan, ADRs (pub-ignored)
└── .github/workflows/{ci,native-release,publish}.yml
```

---

## 6. Example project

Purpose: prove the headless library end to end and be the reference integration other apps copy. Two deliverables share one small `NodeController` layer so the Flutter app contains no networking code of its own.

### 6.1 `examples/tsnode/` — `tsnode`, a headless Dart CLI (milestone M1)

```
tsnode join   --control-url https://headscale.example.com --auth-key tskey-… --hostname demo-a --state-dir ./state --ephemeral
              (or --oauth-client-id … --oauth-client-secret … --tags tag:demo)
tsnode info                     # current node details as a table or --json
tsnode peers                    # name, IPs, online, OS, tags, last seen
tsnode echo   --port 7777       # keep an echo/chat listener running
tsnode send   demo-b 7777 "hi"  # dial a peer by MagicDNS name or IP and print the reply
tsnode fetch  http://demo-b:8080/health   # HTTP over the tailnet via node.httpClient()
```

`join` keeps running, prints state transitions (`Starting → NeedsLogin → Running`) and the login URL as plain text when the interactive credential is chosen. CI runs two `tsnode` processes against the hermetic control server and against Headscale and makes them talk to each other (§7).

### 6.2 `examples/node_console/` — Flutter app (milestone M2)

Targets macOS, iOS, Android and Linux. Three screens, all built on the public API only:

| Screen | Shows / does | Library calls |
|---|---|---|
| **Connect** | Control-server preset (Tailscale / Headscale URL), credential form (auth key, or OAuth client id + secret + tags), hostname, ephemeral switch, Connect / Disconnect / Logout. State banner with the current `BackendState`, health warnings, and the login URL as copyable text if interactive login was chosen. | `TailscaleNode(...)`, `start()`, `waitUntilRunning()`, `state`, `health`, `authUrls`, `logout()`, `close()` |
| **Node** | Current node details: hostname, MagicDNS name, IPv4, IPv6, tailnet name and DNS suffix, backend state, control URL, node ID, OS, key expiry, client version, health list. Peer list refreshed every few seconds: name, IPs, online, last seen, OS, tags. | `addresses`, `status()` (`Self`, `CurrentTailnet`, `Peer`, `Health`) |
| **Communicate** | A chat listener on port 7777 starts automatically once `Running`. Pick a peer and send a text line over TCP; incoming lines appear with the sender resolved via `whoIs`. An HTTP field fetches any tailnet URL through the node and shows status, headers and body size. | `listen(port: 7777)`, `connect(host, port)`, `whoIs(ip)`, `httpClient()` |

Two devices running the app chat with each other; a `tsnode echo` process is the third possible counterpart. State directory comes from `path_provider`; nothing secret is persisted by default. The app has no logic the library does not expose, which is the point: if the app needs something, the library surface is what changes.

### 6.3 Acceptance

- Joins Tailscale and Headscale with an auth key; joins Tailscale with an OAuth client.
- Node screen matches `tailscale status` / the Headscale admin view for the same node.
- Chat works device ↔ device and device ↔ `tsnode echo` in both directions, including after backgrounding and resuming on mobile.
- HTTP fetch reaches a peer's HTTP service by MagicDNS name.

---

## 7. Testing strategy

1. **Unit** (no native code): SOCKS5 codec, NDJSON parser, JSON models against captured `status` fixtures from both Tailscale and Headscale, error mapping, hook manifest/hash logic, reactor bookkeeping with fake fds (pipes).
2. **Hermetic integration** (CI, no network): build `tstestcontrol` as a second dev-only code asset; start an in-process control server + DERP/STUN; spin two `TailscaleNode`s with distinct state dirs; assert `Running`, IPs, listen/accept/dial echo in both directions, half-close, listener close, `status()`/`whoIs()`, IPN bus events, clean shutdown with no leaked fds (mirrors upstream `tsnetctest`).
3. **Headscale integration** (CI service container `ghcr.io/juanfont/headscale`): create user + pre-auth key via CLI, run a node, assert `Running`, MagicDNS name, peer dial; second test drives the interactive path: capture `authUrls` event, complete registration with `headscale auth register --auth-id`, assert transition to `Running`; negative test: wrong control URL surfaces a timeout + health message.
4. **Tailscale SaaS** (optional nightly job with an ephemeral tagged `TS_AUTHKEY` secret): join, dial a known peer, exercise `cert`/Funnel gating.
5. **Examples as tests**: the `tsnode` CLI is the client in hermetic and Headscale CI jobs (two nodes join, exchange messages, fetch over HTTP). The Flutter app is built for macOS, iOS simulator and Android in CI; a manual device checklist covers join, node screen accuracy, chat, background/resume, reconnect.
6. **Leak and stress**: 1 000 sequential dials, 100 concurrent connections, 10 MB transfers each way, memory watch.

---

## 8. Milestones

| # | Milestone | Deliverables | Exit criteria |
|---|---|---|---|
| M0 | Spike (macOS) | Install Go, build `libtailscale.dylib`, minimal `@Native` bindings by hand, CLI that joins a tailnet with an auth key and prints IPs; same against a local Headscale (Docker). | Node reaches `Running` on both control servers; Go runtime inside Dart VM behaves (hot restart, exit). |
| M1 | Core library (macOS + Linux) | ffigen bindings, hook with `build_from_source`, `TailscaleNode` lifecycle + credential model (auth key, OAuth exchange) + state stream, LocalAPI client, SOCKS5 `connect()`/`httpClient()`, `FdReactor` listen/accept/dial, tests 1–3. | Hermetic + Headscale CI green; two `tsnode` instances join, show node details and exchange messages both directions. |
| M2 | Mobile + Flutter example | iOS (device + sim) and Android build recipes, the `node_console` Flutter example (connect, node details, peers, chat, HTTP fetch, §6.2), suspend/resume handling, 16 KB alignment, privacy manifest check. | Example joins Headscale and Tailscale on an iPhone and an Android device, shows correct node details and chats with a peer. |
| M3 | Distribution + 0.1.0 | Native release workflow, download path in hook with hash pinning, docs (README, API docs, Headscale guide), `dart pub publish --dry-run` clean, automated publishing. | `dart pub add libtailscale` works on a clean machine with no Go. |
| M4 | Optional extensions (only when an integrating app needs them) | UDP via SOCKS5 UDP ASSOCIATE, `whoIs`/`ping` helpers, logs stream, prefs for hostname/tags. Taildrop, Funnel, Serve and `cert` stay out unless requested. | Feature tests green; Headscale nodes never reach Tailscale-only paths. |
| M5 | Windows and upstream | Contribute to libtailscale (§10); Windows once upstream compiles; optional C shim reactor for throughput. | Tracked as separate release. |

Rough effort: M0 ≈ 2–3 days, M1 ≈ 2–3 weeks, M2 ≈ 1–2 weeks, M3 ≈ 1 week, M4 ≈ 1–2 weeks.

---

## 9. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `tailscale_up` is uncancellable and `tailscale_close` leaks conns/listeners | Hung isolates, fd leaks | Never rely on `up`; Dart tracks and closes every fd; propose upstream fixes. |
| Funnel helper indexes `CertDomains[0]` unchecked | Go panic kills the process on Headscale | Gate on `status.certDomains.isNotEmpty`; upstream bounds check. |
| Auth URL only printed via stderr | Opt-in interactive login would be invisible | Use IPN bus `BrowseToURL` / status `AuthURL`; propose `tailscale_set_userlogfd` upstream. |
| OAuth secret unusable as auth key through the C API | "auth id" flows fail | Library performs the OAuth → auth-key exchange in Dart (Tailscale API); propose `tailscale_set_advertise_tags` upstream. |
| Loopback listener stale after iOS suspend | LocalAPI/SOCKS5 fail on resume | Prefer fd dial + `status_json` on iOS; re-probe loopback; upstream fix to recreate the listener. |
| UDP over fd loses datagram boundaries | Broken UDP protocols | Document; implement SOCKS5 UDP ASSOCIATE (M4). |
| No Windows in libtailscale | Platform gap | Deferred; documented; upstream track. |
| Go + Dart VM signal/thread interplay | Crashes, hot-reload oddities | M0 spike; keep one `dlopen` per process; document hot-restart behaviour. |
| Binary size (~30–50 MB per arch) and pub.dev limits | App size, package size | Binaries downloaded at build time, `-ldflags "-s -w"`, `-trimpath`; Flutter strips per-arch. |
| `hooks`/`code_assets` API churn | Build breaks on SDK upgrades | Pin ranges, CI on Dart stable + beta. |
| Headscale/tailscale version skew | Registration failures | Pin `tailscale.com`, CI against Headscale stable, document compatibility table. |
| Unreachable control URL gives no error | Silent hang | Timeouts + health reporting in the API. |

---

## 10. Upstream contributions to propose (small, high value)

1. Bounds-check `CertDomains` in `TsnetEnableFunnelToLocalhostPlaintextHttp1`.
2. `tailscale_set_userlogfd` (or route the auth URL through `Logf`), and/or `tailscale_auth_url()`.
3. Make `TsnetClose` cancel `Up` and close listeners/conns (existing TODOs).
4. Recreate the loopback listener when it is gone (iOS suspend).
5. `tailscale_set_advertise_tags` (unblocks tsnet's built-in OAuth client-secret path), plus `Port` and an in-memory store for ephemeral nodes.
6. Publish prebuilt archives from CI (helps every binding).
7. Windows support (revive PR #25).

---

## 11. Decisions needed from the owner

1. ~~Package name~~ Decided: `libtailscale` (available on pub.dev, 2026-09-02). Still open: GitHub org/repo that will host the native release artifacts.
2. ~~Minimum OS versions~~ Decided (2026-09-02): iOS 15, macOS 15 Sequoia, Android 15 / API 35 Vanilla Ice Cream, Linux distributions from 2024 onward (glibc 2.39, Ubuntu 24.04 baseline).
3. Credential forms for v1: auth/pre-auth key and Tailscale OAuth client (id + secret) proposed; interactive login is an opt-in extra. Confirm what "auth id" means for your apps (OAuth client id is assumed).
4. Whether v1 ships the fd-based UDP (stream-like) or waits for SOCKS5 UDP in M4.
5. Whether to vendor libtailscale as a git submodule (proposed) or build it from a Go module reference.
6. Verified-publisher domain for pub.dev.

---

## Appendix A. Build cheat-sheet (from upstream Makefiles and Go platform table)

```bash
# macOS (host arch)
MACOSX_DEPLOYMENT_TARGET=15.0 CGO_ENABLED=1 CGO_CFLAGS=-mmacos-version-min=15.0 CGO_LDFLAGS=-mmacos-version-min=15.0 \
  go build -trimpath -buildvcs=false -ldflags "-s -w" -buildmode=c-shared -o libtailscale.dylib .

# Linux
CGO_ENABLED=1 go build -trimpath -buildvcs=false -ldflags "-s -w" -buildmode=c-shared -o libtailscale.so .

# Android arm64 (NDK r26+)
CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android35-clang \
  CGO_LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-soname,libtailscale.so" \
  go build -trimpath -ldflags "-s -w" -buildmode=c-shared -o libtailscale.so .

# iOS device: c-archive, then link a dylib (c-shared is unsupported for GOOS=ios)
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC=$PWD/swift/script/clangwrap-ios.sh \
  go build -trimpath -tags ios -ldflags -w -buildmode=c-archive -o libtailscale_ios.a .
xcrun --sdk iphoneos clang -dynamiclib -arch arm64 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=15.0 -Wl,-all_load libtailscale_ios.a -framework CoreFoundation -framework Security -lresolv \
  -install_name @rpath/libtailscale.framework/libtailscale -o libtailscale.dylib
# simulator: same with clangwrap-ios-sim-{arm,x86}.sh and --sdk iphonesimulator, then lipo the two slices

# hermetic test control server (dev only)
cd tstestcontrol && go build -buildmode=c-shared -o libtstestcontrol.dylib .
```

## Appendix B. Sources consulted

- libtailscale: `tailscale.h`, `tailscale.c`, `tailscale.go`, `Makefile`, `sourcepkg/Makefile.src`, `swift/TailscaleKit/*.swift`, `swift/script/clangwrap-ios*.sh`, `ruby/lib/tailscale.rb`, `python/src/main.cpp`, `tstestcontrol/*`, `tsnetctest/tsnetctest.go`, `example/echo_server.c`, repo metadata, PRs #25/#57/#59.
- tailscale v1.94.1: `tsnet/tsnet.go` (`Loopback`, `Up`, `start`, `printAuthURLLoop`), `client/local/local.go` (LocalAPI paths), `ipn/localapi/localapi.go`, `ipn/ipnstate/ipnstate.go`, `net/socks5/socks5.go`, pkg.go.dev docs for `tsnet`, `ipn.Notify`, `ipnstate`.
- Headscale `docs/about/features.md`.
- Go `internal/platform/supported.go` (c-shared platform list).
- Dart: dart.dev/tools/hooks, docs.flutter.dev bind-native-code, `package:hooks` 2.2.0, `package:code_assets`, `package:native_toolchain_c` 0.19.4, `package:ffigen` 21.0.0, `HttpClient.connectionFactory`, `ConnectionTask.fromSocket`, hooks `download_asset` example.
- Android 16 KB page-size guidance for Go c-shared libraries.
