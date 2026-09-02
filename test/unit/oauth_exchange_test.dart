// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:libtailscale/libtailscale.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  final requests = <HttpRequest>[];
  final bodies = <String>[];
  var failStep = '';

  setUp(() async {
    requests.clear();
    bodies.clear();
    failStep = '';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req);
      final body = await utf8.decodeStream(req);
      bodies.add(body);
      switch (req.uri.path) {
        case '/api/v2/oauth/token':
          if (failStep == 'token') {
            req.response
              ..statusCode = 401
              ..write('{"message":"invalid client"}');
          } else {
            req.response.write(
              jsonEncode({
                'access_token': 'tskey-api-token',
                'token_type': 'Bearer',
                'expires_in': 3600,
              }),
            );
          }
        case '/api/v2/tailnet/-/keys':
          if (failStep == 'create-key') {
            req.response
              ..statusCode = 403
              ..write('{"message":"forbidden"}');
          } else {
            req.response.write(
              jsonEncode({
                'id': 'k1',
                'key': 'tskey-auth-minted',
                'created': '2026-09-02T00:00:00Z',
              }),
            );
          }
        default:
          req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  const credential = OAuthClientCredential(
    clientId: 'kABC',
    clientSecret: 'tskey-client-xyz',
    tags: ['tag:demo', 'tag:ci'],
    ephemeral: true,
    preauthorized: true,
    keyExpiry: Duration(minutes: 10),
  );

  TailscaleOAuthExchanger exchanger() => TailscaleOAuthExchanger(
    apiBaseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
  );

  test('mints a tagged auth key', () async {
    final key = await exchanger().mintAuthKey(credential, description: 'test');
    expect(key, 'tskey-auth-minted');
    expect(requests, hasLength(2));

    final token = requests[0];
    expect(token.method, 'POST');
    expect(
      token.headers.contentType!.mimeType,
      'application/x-www-form-urlencoded',
    );
    expect(Uri.splitQueryString(bodies[0]), {
      'client_id': 'kABC',
      'client_secret': 'tskey-client-xyz',
    });

    final keys = requests[1];
    expect(
      keys.headers.value(HttpHeaders.authorizationHeader),
      'Bearer tskey-api-token',
    );
    expect(keys.headers.contentType!.mimeType, 'application/json');
    expect(jsonDecode(bodies[1]), {
      'capabilities': {
        'devices': {
          'create': {
            'reusable': false,
            'ephemeral': true,
            'preauthorized': true,
            'tags': ['tag:demo', 'tag:ci'],
          },
        },
      },
      'expirySeconds': 600,
      'description': 'test',
    });
  });

  test('credential apiBaseUrl overrides the exchanger default', () async {
    final custom = OAuthClientCredential(
      clientId: 'a',
      clientSecret: 'b',
      tags: const ['tag:x'],
      apiBaseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    final key = await TailscaleOAuthExchanger(
      apiBaseUrl: Uri.parse('http://127.0.0.1:1'),
    ).mintAuthKey(custom);
    expect(key, 'tskey-auth-minted');
  });

  test('reports token failures', () async {
    failStep = 'token';
    await expectLater(
      exchanger().mintAuthKey(credential),
      throwsA(
        isA<TailscaleOAuthException>()
            .having((e) => e.step, 'step', 'token')
            .having((e) => e.statusCode, 'status', 401),
      ),
    );
  });

  test('reports key creation failures', () async {
    failStep = 'create-key';
    await expectLater(
      exchanger().mintAuthKey(credential),
      throwsA(
        isA<TailscaleOAuthException>()
            .having((e) => e.step, 'step', 'create-key')
            .having((e) => e.body, 'body', contains('forbidden')),
      ),
    );
  });
}
