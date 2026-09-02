// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../ffi/libc.dart';
import '../ffi/tailscale_api.dart';
import '../runtime/fd_reactor.dart';
import '../runtime/local_api.dart';
import '../runtime/native_worker.dart';
import '../runtime/node_events.dart';
import '../runtime/oauth_exchange.dart';
import '../runtime/process_environment.dart';
import '../runtime/socks5.dart';
import 'addresses.dart';
import 'config.dart';
import 'exceptions.dart';
import 'sockets.dart';
import 'state.dart';
import 'status.dart';

enum _Phase { created, starting, started, closed }

/// A headless Tailscale node embedded in this process.
///
/// ```dart
/// final node = TailscaleNode(TailscaleConfig(
///   controlUrl: Uri.parse('https://headscale.example.com'),
///   credential: TailscaleCredential.authKey(preAuthKey),
///   hostname: 'inventory-agent',
///   stateDir: stateDirectory,
/// ));
/// await node.start();
/// await node.waitUntilRunning(timeout: const Duration(seconds: 60));
/// final socket = await node.connect('files', 443);
/// ```
///
/// Every call that can block runs off the calling isolate; the API never
/// blocks a Flutter UI thread. The node renders nothing, opens no browser and
/// uses no platform channels.
final class TailscaleNode {
  /// Creates a node. Nothing happens until [start].
  ///
  /// The optional parameters exist for tests and special environments:
  /// [native] replaces the C bindings, [worker] decides where blocking calls
  /// run, [createReactor] builds the fd reactor, [oauthExchanger] performs
  /// the OAuth key exchange and [createHttpClient] builds the LocalAPI HTTP
  /// clients.
  TailscaleNode(
    this.config, {
    NativeTailscale native = const FfiTailscale(),
    NativeWorker worker = const IsolateNativeWorker(),
    FdReactor Function()? createReactor,
    TailscaleOAuthExchanger? oauthExchanger,
    HttpClient Function()? createHttpClient,
    this.statusPollInterval = const Duration(seconds: 2),
  }) : _native = native,
       _worker = worker,
       _createReactor = createReactor ?? FdReactor.new,
       _oauthExchanger = oauthExchanger ?? TailscaleOAuthExchanger(),
       _createHttpClient = createHttpClient,
       _tracker = NodeStateTracker(credential: config.credential);

  /// The configuration this node was created with.
  final TailscaleConfig config;

  /// Poll interval when falling back from the IPN bus to status polling.
  final Duration statusPollInterval;

  final NativeTailscale _native;
  final NativeWorker _worker;
  final FdReactor Function() _createReactor;
  final TailscaleOAuthExchanger _oauthExchanger;
  final HttpClient Function()? _createHttpClient;
  final NodeStateTracker _tracker;
  final _logs = StreamController<String>.broadcast();

  _Phase _phase = _Phase.created;
  int? _sd;
  LoopbackInfo? _loopback;
  LocalApiClient? _localApi;
  Socks5Client? _socks5;
  FdReactor? _reactor;
  StreamSubscription<IpnNotify>? _events;
  bool _usingLocalApiEvents = false;
  TailscaleAddresses _addresses = TailscaleAddresses.empty;

  // -- lifecycle -------------------------------------------------------------

  /// Whether [start] completed and [close] has not been called.
  bool get isStarted => _phase == _Phase.started;

  /// Whether [close] was called.
  bool get isClosed => _phase == _Phase.closed;

  /// Configures and starts the node, then subscribes to backend events.
  ///
  /// Returns as soon as the backend is running its state machine; use
  /// [waitUntilRunning] to wait for connectivity.
  Future<void> start() async {
    switch (_phase) {
      case _Phase.created:
        break;
      case _Phase.starting:
      case _Phase.started:
        throw StateError('TailscaleNode.start() was already called');
      case _Phase.closed:
        throw const TailscaleClosedException();
    }
    _phase = _Phase.starting;
    config.validate();
    try {
      await Directory(config.stateDir).create(recursive: true);
      final authKey = await _resolveAuthKey();

      // Android app processes have no $HOME/$TMPDIR, which makes tsnet panic.
      for (final name in prepareProcessEnvironment(config.stateDir)) {
        _logs.add('libtailscale: set \$$name=${config.stateDir}');
      }
      final native = _native;
      final sd = native.newServer();
      _sd = sd;
      native
        ..setDir(sd, config.stateDir)
        ..setHostname(sd, config.hostname)
        ..setControlUrl(sd, config.effectiveControlUrl.toString())
        ..setEphemeral(sd, config.ephemeral);
      if (authKey != null) native.setAuthKey(sd, authKey);

      final reactor = _createReactor();
      _reactor = reactor;
      await reactor.start();

      if (config.captureLogs) {
        final (readFd, writeFd) = Libc.pipe();
        native.setLogFd(sd, writeFd);
        final connection = reactor.addConnection(readFd);
        const LineSplitter()
            .bind(utf8.decoder.bind(connection.data))
            .listen(_logs.add, onError: (Object _) {}, onDone: () {});
      } else {
        native.setLogFd(sd, -1);
      }

      await _worker.run(() => native.start(sd), debugName: 'tailscale_start');
      final loopback = await _worker.run(
        () => native.loopback(sd),
        debugName: 'tailscale_loopback',
      );
      _loopback = loopback;
      _localApi = LocalApiClient.fromLoopback(
        loopback,
        createHttpClient: _createHttpClient,
      );
      _socks5 = Socks5Client(
        proxyHost: loopback.host,
        proxyPort: loopback.port,
        username: 'tsnet',
        password: loopback.proxyCredential,
      );
      _phase = _Phase.started;
      _subscribeEvents(useLocalApi: true);
      await refreshAddresses();
    } catch (_) {
      await _teardown();
      _phase = _Phase.closed;
      rethrow;
    }
  }

  Future<String?> _resolveAuthKey() async => switch (config.credential) {
    AuthKeyCredential(:final key) => key,
    final OAuthClientCredential oauth => await _oauthExchanger.mintAuthKey(
      oauth,
      description: 'libtailscale ${config.hostname}',
    ),
    ExistingStateCredential() || InteractiveCredential() => null,
  };

  void _subscribeEvents({required bool useLocalApi}) {
    if (_phase != _Phase.started) return;
    _usingLocalApiEvents = useLocalApi;
    final NodeEventSource source = useLocalApi
        ? LocalApiEventSource(_localApi!)
        : StatusPollEventSource(
            _statusFromNative,
            interval: statusPollInterval,
          );
    _events = source.events().listen(
      _tracker.handle,
      onError: (Object error, StackTrace stackTrace) {
        _tracker.handleError(error, stackTrace);
        if (useLocalApi) _fallBackToPolling();
      },
      onDone: () {
        if (useLocalApi) _fallBackToPolling();
      },
      cancelOnError: false,
    );
  }

  void _fallBackToPolling() {
    if (_phase != _Phase.started || !_usingLocalApiEvents) return;
    _events?.cancel();
    _subscribeEvents(useLocalApi: false);
  }

  /// Waits until the backend is `Running` and the node has tailnet addresses.
  ///
  /// Fails fast with [TailscaleBackendException] on backend errors, with
  /// [TailscaleAuthRequiredException] when an
  /// [TailscaleCredential.existingState] node needs a login, and with
  /// [TailscaleTimeoutException] (carrying the last state and health
  /// messages) when [timeout] elapses.
  Future<void> waitUntilRunning({
    Duration timeout = const Duration(seconds: 60),
  }) {
    _ensureStarted();
    return _tracker.waitUntilRunning(
      timeout: timeout,
      isUsable: () async => (await refreshAddresses()).isNotEmpty,
    );
  }

  /// Logs the node out: the node key is deleted from the state directory and
  /// the backend goes to `NeedsLogin`.
  Future<void> logout() async {
    _ensureStarted();
    await _localApi!.logout();
  }

  /// Shuts the node down and releases every native resource.
  ///
  /// Sockets and listeners are closed first, because `tailscale_close` does
  /// not close them. Safe to call more than once.
  Future<void> close() async {
    if (_phase == _Phase.closed) return;
    if (_phase == _Phase.created) {
      _phase = _Phase.closed;
      await _tracker.dispose();
      await _logs.close();
      return;
    }
    _phase = _Phase.closed;
    await _teardown();
    await _tracker.dispose();
    await _logs.close();
  }

  Future<void> _teardown() async {
    await _events?.cancel();
    _events = null;
    _localApi?.close(force: true);
    _localApi = null;
    // Closing the reactor closes every connection, listener and the log pipe
    // read end. The write end handed to Go is intentionally left open: Go
    // owns that fd number and closing it here could redirect Go's log writes
    // into an unrelated fd opened later.
    await _reactor?.close();
    _reactor = null;
    final sd = _sd;
    _sd = null;
    if (sd != null) {
      final native = _native;
      try {
        await _worker.run(() => native.close(sd), debugName: 'tailscale_close');
      } on TailscaleClosedException {
        // Already gone.
      }
    }
  }

  // -- observation -----------------------------------------------------------

  /// Last known backend state (`null` before the first event).
  BackendState? get state => _tracker.state;

  /// Whether the backend is `Running`.
  bool get isRunning => state == BackendState.running;

  /// Distinct backend state changes.
  Stream<BackendState> get stateChanges => _tracker.stateChanges;

  /// Health messages whenever they change; an empty list means healthy.
  Stream<List<String>> get health => _tracker.healthChanges;

  /// Last known health messages.
  List<String> get currentHealth => _tracker.health;

  /// Login URLs published by the control server. Only meaningful with
  /// [TailscaleCredential.interactive]; the library never opens them.
  Stream<String> get authUrls => _tracker.authUrls;

  /// The last login URL, if any.
  String? get authUrl => _tracker.authUrl;

  /// Raw IPN bus notifications (or synthesised ones when polling).
  Stream<IpnNotify> get notifications => _tracker.notifications;

  /// tsnet backend log lines; empty unless [TailscaleConfig.captureLogs].
  Stream<String> get logs => _logs.stream;

  /// Last known tailnet addresses; see [refreshAddresses].
  TailscaleAddresses get addresses => _addresses;

  /// Reads the node's addresses from libtailscale and caches them.
  Future<TailscaleAddresses> refreshAddresses() async {
    final sd = _sd;
    if (sd == null) return _addresses;
    try {
      _addresses = TailscaleAddresses.parse(_native.getIps(sd));
    } on TailscaleClosedException {
      // Racing with close(); keep the last value.
    }
    return _addresses;
  }

  /// The full node status (this node, peers, tailnet, health, cert domains).
  ///
  /// Uses the LocalAPI when available and falls back to
  /// `tailscale_status_json` otherwise.
  Future<TailscaleStatus> status({bool includePeers = true}) async {
    _ensureStarted();
    final api = _localApi;
    if (api != null && _usingLocalApiEvents) {
      try {
        return await api.status(includePeers: includePeers);
      } on SocketException {
        // Loopback listener gone (seen on iOS after suspend); fall through.
      }
    }
    return _statusFromNative();
  }

  Future<TailscaleStatus> _statusFromNative() async {
    final sd = _sd;
    if (sd == null) throw const TailscaleClosedException();
    final native = _native;
    final json = await _worker.run(
      () => native.statusJson(sd),
      debugName: 'tailscale_status_json',
    );
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) {
      throw const TailscaleBackendException('status is not a JSON object');
    }
    return TailscaleStatus.fromJson(decoded);
  }

  /// Identifies the peer behind a tailnet IP or `ip:port`.
  Future<WhoIsResponse> whoIs(String address) {
    _ensureStarted();
    return _localApi!.whoIs(address);
  }

  /// The authenticated LocalAPI client, for anything the typed surface does
  /// not cover. No compatibility guarantees.
  LocalApiClient get localApi {
    _ensureStarted();
    return _localApi!;
  }

  /// The loopback listener details (SOCKS5 + LocalAPI).
  LoopbackInfo get loopback {
    _ensureStarted();
    return _loopback!;
  }

  // -- operate ---------------------------------------------------------------

  /// Opens a TCP connection to [host]:[port] on the tailnet through the
  /// node's SOCKS5 proxy and returns it as a `dart:io` [Socket].
  ///
  /// [host] may be a tailnet IP, a MagicDNS short name or FQDN. For TLS call
  /// [Socks5Socket.secure] on the result (or use [connectSecure]); do not use
  /// `SecureSocket.secure`.
  Future<Socks5Socket> connect(String host, int port, {Duration? timeout}) {
    _ensureStarted();
    return _socks5!.connect(host, port, timeout: timeout);
  }

  /// [connect] followed by a TLS handshake; returns a real [SecureSocket].
  Future<SecureSocket> connectSecure(
    String host,
    int port, {
    Duration? timeout,
    String? tlsHost,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    List<String>? supportedProtocols,
  }) async {
    final socket = await connect(host, port, timeout: timeout);
    try {
      return await socket.secure(
        host: tlsHost,
        context: context,
        onBadCertificate: onBadCertificate,
        supportedProtocols: supportedProtocols,
      );
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  /// An [HttpClient] whose connections are routed over the tailnet.
  ///
  /// Works with `package:http` (`IOClient`), `dio`'s IO adapter, gRPC and
  /// `WebSocket.connect(customClient:)`. Because connections come from a
  /// custom factory, TLS is set up by the node: pass [context] and
  /// [onBadCertificate] here rather than on the returned client.
  HttpClient httpClient({
    SecurityContext? context,
    bool Function(X509Certificate certificate, String host, int port)?
    onBadCertificate,
    Duration? connectionTimeout,
  }) {
    _ensureStarted();
    final socks5 = _socks5!;
    final client = HttpClient(context: context)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = connectionTimeout;
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final secure = uri.scheme == 'https' || uri.scheme == 'wss';
      final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
      return socks5.startConnect(
        uri.host,
        port,
        timeout: connectionTimeout,
        upgrade: secure
            ? (socket) => socket.secure(
                host: uri.host,
                context: context,
                onBadCertificate: onBadCertificate == null
                    ? null
                    : (cert) => onBadCertificate(cert, uri.host, port),
              )
            : null,
      );
    };
    return client;
  }

  /// Listens for TCP connections on [port] on this node's tailnet addresses.
  Future<TailscaleServerSocket> listen({
    required int port,
    String host = '',
  }) async {
    _ensureStarted();
    RangeError.checkValueInInterval(port, 1, 65535, 'port');
    final sd = _sd!;
    final native = _native;
    final address = _hostPort(host, port);
    final listenerFd = await _worker.run(
      () => native.listen(sd, 'tcp', address),
      debugName: 'tailscale_listen',
    );
    final listener = _reactor!.addListener(listenerFd, serverHandle: sd);
    return TailscaleServerSocket.fromListener(listener, port: port, host: host);
  }

  /// Dials [host]:[port] through libtailscale's fd path and returns a
  /// [TailscaleSocket].
  ///
  /// Prefer [connect] for a real `Socket`; this path does not depend on the
  /// loopback listener, which upstream reports can go stale on iOS after the
  /// app was suspended.
  Future<TailscaleSocket> dial(String host, int port) async {
    _ensureStarted();
    final sd = _sd!;
    final native = _native;
    final address = _hostPort(host, port);
    final fd = await _worker.run(
      () => native.dial(sd, 'tcp', address),
      debugName: 'tailscale_dial',
    );
    final connection = _reactor!.addConnection(fd);
    return TailscaleSocket.fromConnection(
      connection,
      remoteAddress: InternetAddress.tryParse(host),
      remotePort: port,
    );
  }

  /// Enables Tailscale Funnel for a plaintext HTTP/1 server on
  /// `127.0.0.1:[localhostPort]`. Tailscale control plane only.
  ///
  /// Throws [TailscaleUnsupportedException] when the node has no certificate
  /// domains (always the case on Headscale); calling the C function in that
  /// state would crash the process.
  Future<void> enableFunnelToLocalhost(int localhostPort) async {
    _ensureStarted();
    final current = await status(includePeers: false);
    if (!current.supportsCertificates) {
      throw const TailscaleUnsupportedException(
        'Funnel needs a certificate domain; the control server (Headscale?) '
        'did not provide one',
      );
    }
    final sd = _sd!;
    final native = _native;
    await _worker.run(
      () => native.enableFunnelToLocalhostPlaintextHttp1(sd, localhostPort),
      debugName: 'tailscale_enable_funnel',
    );
  }

  // -- helpers ---------------------------------------------------------------

  void _ensureStarted() {
    switch (_phase) {
      case _Phase.started:
        return;
      case _Phase.closed:
        throw const TailscaleClosedException();
      case _Phase.created:
      case _Phase.starting:
        throw StateError('call TailscaleNode.start() first');
    }
  }

  static String _hostPort(String host, int port) {
    if (host.contains(':') && !host.startsWith('[')) return '[$host]:$port';
    return '$host:$port';
  }

  @override
  String toString() =>
      'TailscaleNode(${config.hostname}, $_phase, '
      'state: ${state?.name})';
}
