// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../api/exceptions.dart';
import '../api/state.dart';
import '../api/status.dart';
import '../ffi/tailscale_api.dart';
import 'ndjson.dart';

/// A LocalAPI HTTP response.
final class LocalApiResponse {
  /// Creates a response.
  const LocalApiResponse(this.statusCode, this.headers, this.bodyBytes);

  /// HTTP status code.
  final int statusCode;

  /// Response headers.
  final HttpHeaders headers;

  /// Raw body.
  final Uint8List bodyBytes;

  /// Body decoded as UTF-8.
  String get body => utf8.decode(bodyBytes, allowMalformed: true);

  /// Body decoded as JSON, or `null` when empty.
  Object? json() => bodyBytes.isEmpty ? null : jsonDecode(body);

  /// Whether the status is 2xx.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Client for tailscaled's LocalAPI served on the node's loopback listener.
///
/// Typed wrappers exist only for what the node lifecycle needs; [raw] reaches
/// everything else in `tailscale.com/client/local` without support
/// guarantees.
final class LocalApiClient {
  /// Creates a client for the LocalAPI at `http://host:port`.
  LocalApiClient({
    required this.host,
    required this.port,
    required String credential,
    HttpClient Function()? createHttpClient,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _authorization = 'Basic ${base64Encode(utf8.encode(':$credential'))}',
       _createHttpClient = createHttpClient ?? _defaultHttpClient {
    _client = _createHttpClient();
  }

  /// Creates a client from the result of `tailscale_loopback`.
  factory LocalApiClient.fromLoopback(
    LoopbackInfo info, {
    HttpClient Function()? createHttpClient,
  }) => LocalApiClient(
    host: info.host,
    port: info.port,
    credential: info.localApiCredential,
    createHttpClient: createHttpClient,
  );

  /// Path prefix of every endpoint.
  static const pathPrefix = '/localapi/v0/';

  /// Loopback host.
  final String host;

  /// Loopback port.
  final int port;

  /// Timeout for ordinary (non-streaming) requests.
  final Duration requestTimeout;

  final String _authorization;
  final HttpClient Function() _createHttpClient;
  late final HttpClient _client;
  bool _closed = false;

  static HttpClient _defaultHttpClient() => HttpClient()
    // Never route loopback traffic through an environment proxy.
    ..findProxy = ((_) => 'DIRECT')
    ..idleTimeout = const Duration(seconds: 15);

  Uri _uri(String path, Map<String, String>? query) => Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: path.startsWith('/') ? path : '$pathPrefix$path',
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  void _authenticate(HttpClientRequest request) {
    request.headers
      ..set('Sec-Tailscale', 'localapi')
      ..set(HttpHeaders.authorizationHeader, _authorization);
  }

  /// Performs an arbitrary LocalAPI request.
  ///
  /// [path] is either an endpoint name relative to `/localapi/v0/` (e.g.
  /// `status`) or an absolute path. A [body] that is a `Map` or `List` is
  /// JSON-encoded; a `String` is sent as UTF-8; a `List<int>` is sent as is.
  Future<LocalApiResponse> raw(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    if (_closed) throw const TailscaleClosedException('LocalApiClient closed');
    final uri = _uri(path, query);
    final request = await _client.openUrl(method, uri);
    _authenticate(request);
    headers?.forEach(request.headers.set);
    if (body != null) {
      switch (body) {
        case final String s:
          request.headers.contentType ??= ContentType.text;
          request.write(s);
        case final List<int> bytes:
          request.add(bytes);
        case Map<String, Object?>() || List<Object?>():
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        default:
          throw ArgumentError.value(body, 'body', 'unsupported body type');
      }
    }
    final response = await request.close().timeout(timeout ?? requestTimeout);
    final bytes = await _collect(response).timeout(timeout ?? requestTimeout);
    return LocalApiResponse(response.statusCode, response.headers, bytes);
  }

  Future<LocalApiResponse> _expectSuccess(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final res = await raw(method, path, query: query, body: body);
    if (!res.isSuccess) {
      throw LocalApiException(
        method,
        _uri(path, query).toString(),
        res.statusCode,
        res.body,
      );
    }
    return res;
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final res = await _expectSuccess(method, path, query: query, body: body);
    final decoded = res.json();
    if (decoded is! Map<String, Object?>) {
      throw LocalApiException(
        method,
        _uri(path, query).toString(),
        res.statusCode,
        'expected a JSON object, got: ${res.body}',
      );
    }
    return decoded;
  }

  /// `GET status`: the full node status, optionally without peers.
  Future<TailscaleStatus> status({bool includePeers = true}) async =>
      TailscaleStatus.fromJson(
        await _json(
          'GET',
          'status',
          query: includePeers ? null : const {'peers': 'false'},
        ),
      );

  /// `GET whois?addr=`: the identity behind a tailnet IP or `ip:port`.
  Future<WhoIsResponse> whoIs(String address) async => WhoIsResponse.fromJson(
    await _json('GET', 'whois', query: {'addr': address}),
  );

  /// `POST logout`: drops the node key.
  Future<void> logout() => _expectSuccess('POST', 'logout');

  /// `POST login-interactive`: asks control for a login URL.
  Future<void> loginInteractive() =>
      _expectSuccess('POST', 'login-interactive');

  /// `GET prefs`: the current `ipn.Prefs` as JSON.
  Future<Map<String, Object?>> prefs() => _json('GET', 'prefs');

  /// `PATCH prefs`: applies an `ipn.MaskedPrefs` document, e.g.
  /// `{'Hostname': 'new-name', 'HostnameSet': true}`. Returns the new prefs.
  Future<Map<String, Object?>> editPrefs(Map<String, Object?> maskedPrefs) =>
      _json('PATCH', 'prefs', body: maskedPrefs);

  /// `GET watch-ipn-bus?mask=`: a stream of [IpnNotify] messages.
  ///
  /// Each subscription opens its own long-lived HTTP request; cancelling the
  /// subscription closes it. Decoding errors for single lines are reported as
  /// errors on the stream without ending it.
  Stream<IpnNotify> watchIpnBus({int mask = IpnWatchOptions.nodeDefaults}) {
    if (_closed) throw const TailscaleClosedException('LocalApiClient closed');
    late final StreamController<IpnNotify> controller;
    HttpClient? client;
    StreamSubscription<Map<String, Object?>>? subscription;
    var cancelled = false;

    Future<void> start() async {
      client = _createHttpClient();
      try {
        final uri = _uri('watch-ipn-bus', {'mask': '$mask'});
        final request = await client!.getUrl(uri);
        _authenticate(request);
        final response = await request.close();
        if (cancelled) {
          client?.close(force: true);
          return;
        }
        if (response.statusCode != HttpStatus.ok) {
          final body = await utf8.decodeStream(response);
          if (!cancelled && !controller.isClosed) {
            controller.addError(
              LocalApiException(
                'GET',
                uri.toString(),
                response.statusCode,
                body,
              ),
            );
            await controller.close();
          }
          return;
        }
        subscription = response
            .transform(const NdjsonDecoder())
            .listen(
              (json) {
                if (!cancelled) controller.add(IpnNotify.fromJson(json));
              },
              onError: (Object e, StackTrace st) {
                if (!cancelled) controller.addError(e, st);
              },
              onDone: () {
                if (!cancelled) controller.close();
              },
              cancelOnError: false,
            );
      } catch (e, st) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(e, st);
          await controller.close();
        }
      }
    }

    controller = StreamController<IpnNotify>(
      onListen: start,
      onCancel: () async {
        cancelled = true;
        // Destroying the connection first guarantees the response stream
        // ends, so cancelling the subscription cannot block.
        client?.close(force: true);
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// Closes idle connections. Pass `force: true` to abort in-flight requests.
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _client.close(force: force);
  }

  static Future<Uint8List> _collect(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
