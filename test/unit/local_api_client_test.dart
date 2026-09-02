// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:libtailscale/libtailscale.dart';
import 'package:test/test.dart';

import '../helpers/fake_local_api.dart';

void main() {
  late FakeLocalApi api;
  late LocalApiClient client;

  setUp(() async {
    api = FakeLocalApi('c' * 32);
    await api.start();
    client = LocalApiClient(
      host: '127.0.0.1',
      port: api.port,
      credential: 'c' * 32,
    );
  });

  tearDown(() async {
    client.close(force: true);
    await api.close();
  });

  test('status sends the security header and basic auth', () async {
    final status = await client.status();
    expect(status.isRunning, isTrue);
    expect(api.requests.single.uri.queryParameters, isEmpty);
    await client.status(includePeers: false);
    expect(api.requests.last.uri.queryParameters, {'peers': 'false'});
  });

  test('whoIs', () async {
    final who = await client.whoIs('100.101.102.104');
    expect(who.node.shortName, 'demo-b');
    await expectLater(
      client.whoIs('100.1.1.1'),
      throwsA(
        isA<LocalApiException>()
            .having((e) => e.statusCode, 'status', 404)
            .having((e) => e.message, 'message', contains('no match')),
      ),
    );
  });

  test('logout, loginInteractive and prefs', () async {
    await client.logout();
    await client.loginInteractive();
    expect(api.requests.map((r) => r.method), ['POST', 'POST']);
    expect((await client.prefs())['Hostname'], 'demo-a');
    final updated = await client.editPrefs({
      'Hostname': 'renamed',
      'HostnameSet': true,
    });
    expect(updated['Hostname'], 'renamed');
    expect(api.requests.last.method, 'PATCH');
  });

  test('wrong credential yields 401 LocalApiException', () async {
    final bad = LocalApiClient(
      host: '127.0.0.1',
      port: api.port,
      credential: 'nope',
    );
    await expectLater(
      bad.status(),
      throwsA(
        isA<LocalApiException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    bad.close();
  });

  test('raw reaches arbitrary endpoints', () async {
    final res = await client.raw('GET', 'status');
    expect(res.isSuccess, isTrue);
    expect(res.json(), isA<Map<String, Object?>>());
    final missing = await client.raw('GET', '/localapi/v0/nope');
    expect(missing.statusCode, 404);
  });

  test('watchIpnBus streams notifications and stops on cancel', () async {
    api.busLines = File(
      'test/fixtures/ipn_bus.ndjson',
    ).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
    final received = <IpnNotify>[];
    final sub = client.watchIpnBus(mask: 130).listen(received.add);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(api.requests.last.uri.queryParameters, {'mask': '130'});
    expect(received.map((n) => n.state), [
      BackendState.starting,
      BackendState.needsLogin,
      BackendState.starting,
      BackendState.running,
      null,
    ]);
    expect(received.last.errMessage, 'invalid key: key expired');
    await sub.cancel();
    await api.busClosed.future.timeout(const Duration(seconds: 5));
  });

  test('watchIpnBus reports HTTP errors', () async {
    final bad = LocalApiClient(
      host: '127.0.0.1',
      port: api.port,
      credential: 'nope',
    );
    await expectLater(
      bad.watchIpnBus().first,
      throwsA(
        isA<LocalApiException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    bad.close();
  });

  test('closed client rejects requests', () {
    client.close();
    expect(client.status(), throwsA(isA<TailscaleClosedException>()));
  });
}
