// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../api/exceptions.dart';

/// SOCKS5 wire format helpers (RFC 1928 and RFC 1929).
///
/// Pure functions, no I/O: everything here is unit-testable without a proxy.
abstract final class Socks5 {
  /// Protocol version byte.
  static const int version = 0x05;

  /// "No authentication required" method.
  static const int methodNoAuth = 0x00;

  /// Username/password method (RFC 1929).
  static const int methodUserPass = 0x02;

  /// "No acceptable methods" answer from the server.
  static const int methodNoAcceptable = 0xFF;

  /// RFC 1929 sub-negotiation version.
  static const int userPassVersion = 0x01;

  /// CONNECT command.
  static const int cmdConnect = 0x01;

  /// IPv4 address type.
  static const int atypIPv4 = 0x01;

  /// Domain name address type.
  static const int atypDomain = 0x03;

  /// IPv6 address type.
  static const int atypIPv6 = 0x04;

  /// Reply code for success.
  static const int replySucceeded = 0x00;

  /// Human-readable text for an RFC 1928 reply code.
  static String replyMessage(int code) => switch (code) {
    0x00 => 'succeeded',
    0x01 => 'general SOCKS server failure',
    0x02 => 'connection not allowed by ruleset',
    0x03 => 'network unreachable',
    0x04 => 'host unreachable',
    0x05 => 'connection refused',
    0x06 => 'TTL expired',
    0x07 => 'command not supported',
    0x08 => 'address type not supported',
    _ => 'unknown reply code $code',
  };

  /// The client greeting offering [methods].
  static Uint8List greeting(List<int> methods) {
    if (methods.isEmpty || methods.length > 255) {
      throw ArgumentError.value(methods, 'methods', 'need 1..255 methods');
    }
    return Uint8List.fromList([version, methods.length, ...methods]);
  }

  /// The RFC 1929 username/password request.
  static Uint8List userPassRequest(String username, String password) {
    final u = utf8.encode(username);
    final p = utf8.encode(password);
    if (u.isEmpty || u.length > 255) {
      throw ArgumentError.value(username, 'username', 'must be 1..255 bytes');
    }
    if (p.length > 255) {
      throw ArgumentError.value(
        '<redacted>',
        'password',
        'must be <=255 bytes',
      );
    }
    return Uint8List.fromList([
      userPassVersion,
      u.length,
      ...u,
      p.length,
      ...p,
    ]);
  }

  /// A CONNECT request for [host]:[port].
  ///
  /// IP literals are sent as IPv4/IPv6 addresses; anything else as a domain
  /// name so the proxy (tsnet) resolves MagicDNS names itself.
  static Uint8List connectRequest(String host, int port) {
    RangeError.checkValueInInterval(port, 0, 65535, 'port');
    var h = host;
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    final ip = InternetAddress.tryParse(h);
    final List<int> addr;
    if (ip == null) {
      final name = utf8.encode(h);
      if (name.isEmpty || name.length > 255) {
        throw ArgumentError.value(host, 'host', 'must be 1..255 bytes');
      }
      addr = [atypDomain, name.length, ...name];
    } else if (ip.type == InternetAddressType.IPv4) {
      addr = [atypIPv4, ...ip.rawAddress];
    } else {
      addr = [atypIPv6, ...ip.rawAddress];
    }
    return Uint8List.fromList([
      version,
      cmdConnect,
      0x00,
      ...addr,
      (port >> 8) & 0xFF,
      port & 0xFF,
    ]);
  }
}

/// The server's answer to a CONNECT request.
final class Socks5Reply {
  /// Creates a reply.
  const Socks5Reply({required this.bindAddress, required this.bindPort});

  /// `BND.ADDR` (for tsnet: the node's own tailnet address).
  final String bindAddress;

  /// `BND.PORT`.
  final int bindPort;

  @override
  String toString() => 'Socks5Reply($bindAddress:$bindPort)';
}

enum _Stage { methodSelection, authReply, connectReply, done }

/// Incremental client-side SOCKS5 CONNECT handshake.
///
/// Feed it whatever bytes arrive from the proxy; it returns the bytes to send
/// back and tells you when the tunnel is established. Bytes that arrive after
/// the final reply belong to the tunnelled connection and are kept in
/// [leftover].
final class Socks5Handshake {
  /// Creates a handshake for [host]:[port], optionally with credentials.
  Socks5Handshake({
    required this.host,
    required this.port,
    this.username,
    this.password,
  }) {
    if ((username == null) != (password == null)) {
      throw ArgumentError('username and password must be given together');
    }
  }

  /// Target host (IP literal or domain name).
  final String host;

  /// Target port.
  final int port;

  /// RFC 1929 username, if authenticating.
  final String? username;

  /// RFC 1929 password, if authenticating.
  final String? password;

  final List<int> _buffer = <int>[];
  _Stage _stage = _Stage.methodSelection;
  Socks5Reply? _reply;
  Uint8List _leftover = Uint8List(0);

  /// The first message to send to the proxy.
  Uint8List get initialRequest => Socks5.greeting([
    if (username != null) Socks5.methodUserPass,
    Socks5.methodNoAuth,
  ]);

  /// Whether the CONNECT reply was received successfully.
  bool get isComplete => _stage == _Stage.done;

  /// The successful reply, once [isComplete].
  Socks5Reply? get reply => _reply;

  /// Bytes received after the CONNECT reply (tunnel payload).
  Uint8List get leftover => _leftover;

  /// Consumes [data] from the proxy and returns bytes to send (possibly empty).
  ///
  /// Throws [Socks5Exception] on protocol errors or a failed CONNECT.
  Uint8List feed(List<int> data) {
    if (isComplete) {
      throw StateError('handshake already complete');
    }
    _buffer.addAll(data);
    final out = BytesBuilder(copy: false);
    var progressed = true;
    while (progressed && _stage != _Stage.done) {
      progressed = switch (_stage) {
        _Stage.methodSelection => _methodSelection(out),
        _Stage.authReply => _authReply(out),
        _Stage.connectReply => _connectReply(),
        _Stage.done => false,
      };
    }
    return out.toBytes();
  }

  bool _methodSelection(BytesBuilder out) {
    if (_buffer.length < 2) return false;
    final ver = _buffer[0];
    final method = _buffer[1];
    _buffer.removeRange(0, 2);
    if (ver != Socks5.version) {
      throw Socks5Exception('unexpected SOCKS version $ver');
    }
    switch (method) {
      case Socks5.methodNoAuth:
        out.add(Socks5.connectRequest(host, port));
        _stage = _Stage.connectReply;
      case Socks5.methodUserPass:
        if (username == null) {
          throw const Socks5Exception(
            'proxy requires username/password but none were given',
          );
        }
        out.add(Socks5.userPassRequest(username!, password!));
        _stage = _Stage.authReply;
      case Socks5.methodNoAcceptable:
        throw const Socks5Exception('proxy accepts none of our auth methods');
      default:
        throw Socks5Exception('proxy selected unsupported method $method');
    }
    return true;
  }

  bool _authReply(BytesBuilder out) {
    if (_buffer.length < 2) return false;
    final ver = _buffer[0];
    final status = _buffer[1];
    _buffer.removeRange(0, 2);
    if (ver != Socks5.userPassVersion) {
      throw Socks5Exception('unexpected auth sub-negotiation version $ver');
    }
    if (status != 0) {
      throw const Socks5Exception('proxy rejected the credentials');
    }
    out.add(Socks5.connectRequest(host, port));
    _stage = _Stage.connectReply;
    return true;
  }

  bool _connectReply() {
    if (_buffer.length < 4) return false;
    final ver = _buffer[0];
    final rep = _buffer[1];
    final atyp = _buffer[3];
    if (ver != Socks5.version) {
      throw Socks5Exception('unexpected SOCKS version $ver in reply');
    }
    final int addrLen;
    switch (atyp) {
      case Socks5.atypIPv4:
        addrLen = 4;
      case Socks5.atypIPv6:
        addrLen = 16;
      case Socks5.atypDomain:
        if (_buffer.length < 5) return false;
        addrLen = 1 + _buffer[4];
      default:
        throw Socks5Exception('unknown address type $atyp in reply');
    }
    final total = 4 + addrLen + 2;
    if (_buffer.length < total) return false;
    if (rep != Socks5.replySucceeded) {
      throw Socks5Exception(
        'CONNECT to $host:$port failed: ${Socks5.replyMessage(rep)}',
        replyCode: rep,
      );
    }
    final addrBytes = _buffer.sublist(4, 4 + addrLen);
    final bindAddress = switch (atyp) {
      Socks5.atypIPv4 || Socks5.atypIPv6 => InternetAddress.fromRawAddress(
        Uint8List.fromList(addrBytes),
      ).address,
      _ => utf8.decode(addrBytes.sublist(1), allowMalformed: true),
    };
    final bindPort = (_buffer[4 + addrLen] << 8) | _buffer[5 + addrLen];
    _reply = Socks5Reply(bindAddress: bindAddress, bindPort: bindPort);
    _leftover = Uint8List.fromList(_buffer.sublist(total));
    _buffer.clear();
    _stage = _Stage.done;
    return true;
  }
}

/// A TCP connection tunnelled through a SOCKS5 proxy, usable as a
/// `dart:io` [Socket].
///
/// The handshake consumes the underlying socket's stream, so this class
/// wraps it and re-exposes the tunnel payload. Because `dart:io` can only
/// upgrade *its own* sockets to TLS, do not call `SecureSocket.secure` on a
/// [Socks5Socket]; use [secure] instead, which upgrades the underlying socket.
final class Socks5Socket extends Stream<Uint8List> implements Socket {
  Socks5Socket._(
    this._inner,
    this._subscription,
    this.targetHost,
    this.targetPort,
    this.reply,
    Uint8List leftover,
  ) {
    _controller = StreamController<Uint8List>(
      onListen: _subscription.resume,
      onPause: _subscription.pause,
      onResume: _subscription.resume,
      // Mirrors dart:io: cancelling the subscription stops reading for good.
      onCancel: _subscription.cancel,
    );
    if (leftover.isNotEmpty) _controller.add(leftover);
    _subscription
      ..onData(_controller.add)
      ..onError(_controller.addError)
      ..onDone(_controller.close);
  }

  final Socket _inner;
  final StreamSubscription<Uint8List> _subscription;
  late final StreamController<Uint8List> _controller;
  bool _detached = false;

  /// The tailnet host this socket is connected to (as given to `connect`).
  final String targetHost;

  /// The tailnet port this socket is connected to.
  final int targetPort;

  /// The proxy's CONNECT reply.
  final Socks5Reply reply;

  /// Upgrades the tunnel to TLS and returns a real [SecureSocket].
  ///
  /// Must be called before listening to this socket. [host] defaults to
  /// [targetHost] and is used for SNI and certificate validation.
  Future<SecureSocket> secure({
    String? host,
    SecurityContext? context,
    bool Function(X509Certificate certificate)? onBadCertificate,
    void Function(String line)? keyLog,
    List<String>? supportedProtocols,
  }) {
    if (_detached) throw StateError('socket already upgraded to TLS');
    if (_controller.hasListener) {
      throw StateError('cannot upgrade to TLS after listening to the socket');
    }
    _detached = true;
    return SecureSocket.secure(
      _inner,
      host: host ?? targetHost,
      context: context,
      onBadCertificate: onBadCertificate,
      keyLog: keyLog,
      supportedProtocols: supportedProtocols,
    );
  }

  void _checkAttached() {
    if (_detached) {
      throw StateError(
        'Socks5Socket was upgraded to TLS; use the SecureSocket',
      );
    }
  }

  // -- Stream<Uint8List> -----------------------------------------------------

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _checkAttached();
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  // -- Socket ----------------------------------------------------------------

  /// The local (loopback) address of the proxy connection.
  @override
  InternetAddress get address => _inner.address;

  /// The local port of the proxy connection.
  @override
  int get port => _inner.port;

  /// The target address when [targetHost] is an IP literal.
  ///
  /// For domain-name targets the proxy does not tell us the resolved address,
  /// so this throws; use [targetHost] instead.
  @override
  InternetAddress get remoteAddress {
    final ip = InternetAddress.tryParse(targetHost);
    if (ip == null) {
      throw SocketException(
        'remote address unknown for domain target $targetHost',
      );
    }
    return ip;
  }

  @override
  int get remotePort => targetPort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);

  @override
  void destroy() {
    _inner.destroy();
    if (!_controller.isClosed) _controller.close();
  }

  // -- IOSink ----------------------------------------------------------------

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) {
    _checkAttached();
    _inner.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _checkAttached();
    return _inner.addStream(stream);
  }

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  Future<void> flush() => _inner.flush();

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}

/// Opens TCP connections through a SOCKS5 proxy (tsnet's loopback listener).
final class Socks5Client {
  /// Creates a client for the proxy at [proxyHost]:[proxyPort].
  const Socks5Client({
    required this.proxyHost,
    required this.proxyPort,
    this.username,
    this.password,
    this.handshakeTimeout = const Duration(seconds: 30),
  });

  /// Proxy host, normally `127.0.0.1`.
  final String proxyHost;

  /// Proxy port.
  final int proxyPort;

  /// RFC 1929 username (`tsnet` for libtailscale).
  final String? username;

  /// RFC 1929 password (the proxy credential from `tailscale_loopback`).
  final String? password;

  /// Maximum time for the TCP connect plus the SOCKS5 handshake.
  final Duration handshakeTimeout;

  /// Connects to [host]:[port] through the proxy.
  Future<Socks5Socket> connect(String host, int port, {Duration? timeout}) =>
      _connect(host, port, timeout ?? handshakeTimeout, _CancelToken());

  /// Like [connect] but returns a cancellable [ConnectionTask], as required by
  /// `HttpClient.connectionFactory`. [upgrade] can turn the tunnel into a
  /// [SecureSocket] before it is handed to the caller.
  ConnectionTask<Socket> startConnect(
    String host,
    int port, {
    Duration? timeout,
    Future<Socket> Function(Socks5Socket socket)? upgrade,
  }) {
    final token = _CancelToken();
    final future = _connect(
      host,
      port,
      timeout ?? handshakeTimeout,
      token,
    ).then<Socket>((s) => upgrade == null ? s : upgrade(s));
    return ConnectionTask.fromSocket(future, token.cancel);
  }

  Future<Socks5Socket> _connect(
    String host,
    int port,
    Duration timeout,
    _CancelToken token,
  ) async {
    final deadline = DateTime.now().add(timeout);
    final socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
    if (token.cancelled) {
      socket.destroy();
      throw const SocketException('connection attempt cancelled');
    }
    token.socket = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);

    final handshake = Socks5Handshake(
      host: host,
      port: port,
      username: username,
      password: password,
    );
    final completer = Completer<Uint8List>();
    // The subscription outlives this method: Socks5Socket takes it over.
    // ignore: cancel_subscriptions
    late final StreamSubscription<Uint8List> subscription;
    subscription = socket.listen(
      (data) {
        if (completer.isCompleted) return;
        try {
          final out = handshake.feed(data);
          if (out.isNotEmpty) socket.add(out);
          if (handshake.isComplete) {
            subscription.pause();
            completer.complete(handshake.leftover);
          }
        } catch (e, st) {
          completer.completeError(e, st);
        }
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
            const Socks5Exception('proxy closed the connection mid-handshake'),
          );
        }
      },
      cancelOnError: false,
    );
    socket.add(handshake.initialRequest);

    final Uint8List leftover;
    try {
      final remaining = deadline.difference(DateTime.now());
      leftover = await completer.future.timeout(
        remaining.isNegative ? Duration.zero : remaining,
        onTimeout: () => throw TimeoutException(
          'SOCKS5 handshake to $host:$port timed out',
          timeout,
        ),
      );
    } catch (_) {
      socket.destroy();
      rethrow;
    }
    if (token.cancelled) {
      socket.destroy();
      throw const SocketException('connection attempt cancelled');
    }
    return Socks5Socket._(
      socket,
      subscription,
      host,
      port,
      handshake.reply!,
      leftover,
    );
  }
}

final class _CancelToken {
  bool cancelled = false;
  Socket? socket;

  void cancel() {
    cancelled = true;
    socket?.destroy();
  }
}
