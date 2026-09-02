// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A fake tailscaled LocalAPI that enforces the `Sec-Tailscale` header and
/// basic auth, serves fixtures and streams a configurable IPN bus.
final class FakeLocalApi {
  FakeLocalApi(this.credential);

  final String credential;
  late HttpServer server;
  final requests = <HttpRequest>[];
  final busClosed = Completer<void>();

  /// NDJSON lines to stream on `watch-ipn-bus` (a null entry waits for
  /// [busGate] before continuing).
  List<String?> busLines = [];
  Duration busDelay = const Duration(milliseconds: 10);
  Completer<void> busGate = Completer<void>();
  String statusFixture = 'test/fixtures/status_tailscale.json';
  int logoutCalls = 0;

  int get port => server.port;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    requests.add(req);
    if (req.headers.value('Sec-Tailscale') != 'localapi') {
      req.response
        ..statusCode = 403
        ..write("missing 'Sec-Tailscale: localapi' header");
      await req.response.close();
      return;
    }
    final expected = 'Basic ${base64Encode(utf8.encode(':$credential'))}';
    if (req.headers.value(HttpHeaders.authorizationHeader) != expected) {
      req.response
        ..statusCode = 401
        ..write('auth required');
      await req.response.close();
      return;
    }
    final body = await utf8.decodeStream(req);
    switch (req.uri.path) {
      case '/localapi/v0/status':
        req.response.write(File(statusFixture).readAsStringSync());
      case '/localapi/v0/whois':
        if (req.uri.queryParameters['addr'] == '100.101.102.104') {
          req.response.write(
            File('test/fixtures/whois.json').readAsStringSync(),
          );
        } else {
          req.response
            ..statusCode = 404
            ..write('no match for IP:port');
        }
      case '/localapi/v0/logout':
        logoutCalls++;
        req.response.statusCode = req.method == 'POST' ? 204 : 405;
      case '/localapi/v0/login-interactive':
        req.response.statusCode = req.method == 'POST' ? 204 : 405;
      case '/localapi/v0/prefs':
        req.response.write(
          jsonEncode({
            'Hostname': req.method == 'PATCH'
                ? (jsonDecode(body) as Map<String, Object?>)['Hostname']
                : 'demo-a',
            'WantRunning': true,
          }),
        );
      case '/localapi/v0/watch-ipn-bus':
        req.response.headers.contentType = ContentType.json;
        req.response.bufferOutput = false;
        try {
          for (final line in busLines) {
            if (line == null) {
              await busGate.future;
              continue;
            }
            req.response.write('$line\n');
            await req.response.flush();
            await Future<void>.delayed(busDelay);
          }
          // Keep the stream open until the client goes away. A server only
          // notices a vanished client when it writes, and dart:io reports
          // that through `done`, so send blank keepalive lines (skipped by
          // the NDJSON decoder) while awaiting it.
          var stopped = false;
          unawaited(() async {
            while (!stopped) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              if (stopped) break;
              // No flush: it never completes once the peer is gone, while a
              // plain write makes `done` fire.
              try {
                req.response.write('\n');
              } catch (_) {
                break;
              }
            }
          }());
          try {
            await req.response.done;
          } finally {
            stopped = true;
          }
        } catch (_) {
          // client disconnected
        }
        if (!busClosed.isCompleted) busClosed.complete();
        return;
      default:
        req.response.statusCode = 404;
    }
    await req.response.close();
  }
}
