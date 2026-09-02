// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

@Tags(['native'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libtailscale/libtailscale.dart';
import 'package:libtailscale/src/ffi/libc.dart';
import 'package:libtailscale/src/runtime/fd_reactor.dart';
import 'package:test/test.dart';

import '../helpers/fake_local_api.dart';
import '../helpers/fake_native.dart';
import '../helpers/fake_socks5_proxy.dart';
import '../helpers/libc_io.dart';
import '../helpers/loopback_mux.dart';

const _running = '{"State":6,"Health":{"Warnings":{}}}';
const _starting =
    '{"State":5,"Health":{"Warnings":{"warming-up":{"WarnableCode":"warming-up","Title":"Starting","Text":"Tailscale is starting."}}}}';
const _needsLogin =
    '{"State":2,"BrowseToURL":"https://headscale.example.com/register/mkey:abc"}';

final class _FakeExchanger extends TailscaleOAuthExchanger {
  final calls = <OAuthClientCredential>[];

  @override
  Future<String> mintAuthKey(
    OAuthClientCredential credential, {
    String description = 'libtailscale',
  }) async {
    calls.add(credential);
    return 'tskey-auth-minted';
  }
}

void main() {
  late Directory temp;
  late FakeLocalApi localApi;
  late EchoServer echo;
  late FakeSocks5Proxy socks;
  late LoopbackMux mux;
  late FakeNative native;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('libtailscale-node');
    localApi = FakeLocalApi('l' * 32);
    await localApi.start();
    echo = EchoServer(banner: 'ECHO\n');
    await echo.start();
    socks = FakeSocks5Proxy(
      username: 'tsnet',
      password: 'p' * 32,
      resolveTarget: (host, port) =>
          Socket.connect(InternetAddress.loopbackIPv4, echo.port),
    );
    await socks.start();
    mux = LoopbackMux(socksPort: socks.port, httpPort: localApi.port);
    await mux.start();
    native = FakeNative(loopbackPort: mux.port);
  });

  tearDown(() async {
    native.dispose();
    await mux.close();
    await socks.close();
    await echo.close();
    await localApi.close();
    await temp.delete(recursive: true);
  });

  TailscaleNode makeNode(
    TailscaleConfig config, {
    TailscaleOAuthExchanger? oauth,
  }) => TailscaleNode(
    config,
    native: native,
    worker: const InlineNativeWorker(),
    createReactor: () => FdReactor(accept: fakeAccept),
    oauthExchanger: oauth,
    statusPollInterval: const Duration(milliseconds: 50),
  );

  TailscaleConfig config({
    TailscaleCredential credential = const TailscaleCredential.authKey(
      'tskey-auth-x',
    ),
    Uri? controlUrl,
    bool captureLogs = false,
  }) => TailscaleConfig(
    controlUrl: controlUrl,
    credential: credential,
    hostname: 'demo-a',
    stateDir: '${temp.path}/state',
    ephemeral: true,
    captureLogs: captureLogs,
  );

  test(
    'start configures libtailscale and waitUntilRunning follows the bus',
    () async {
      localApi.busLines = [_starting, _running];
      final node = makeNode(
        config(controlUrl: Uri.parse('https://hs.example.com')),
      );
      final states = <BackendState>[];
      node.stateChanges.listen(states.add);
      final healths = <List<String>>[];
      node.health.listen(healths.add);

      await node.start();
      expect(node.isStarted, isTrue);
      expect(native.calls, [
        'newServer',
        'setDir',
        'setHostname',
        'setControlUrl',
        'setEphemeral',
        'setAuthKey',
        'setLogFd',
        'start',
        'loopback',
      ]);
      expect(native.settings, {
        'dir': '${temp.path}/state',
        'hostname': 'demo-a',
        'controlUrl': 'https://hs.example.com',
        'ephemeral': true,
        'authKey': 'tskey-auth-x',
      });
      expect(native.logFd, -1);
      expect(Directory('${temp.path}/state').existsSync(), isTrue);
      expect(node.addresses.isEmpty, isTrue);

      // IPs show up a little after Running: exercises the re-check loop.
      Timer(const Duration(milliseconds: 150), () {
        native.ips = '100.64.0.1,fd7a:115c:a1e0::1';
      });
      await node.waitUntilRunning(timeout: const Duration(seconds: 5));
      expect(node.isRunning, isTrue);
      expect(node.addresses.ipv4!.address, '100.64.0.1');
      expect(states, [BackendState.starting, BackendState.running]);
      expect(healths, [
        ['Tailscale is starting.'],
        <String>[],
      ]);
      expect(node.currentHealth, isEmpty);

      // Status and whois go through the LocalAPI.
      final status = await node.status();
      expect(status.self!.name, 'demo-a');
      expect((await node.whoIs('100.101.102.104')).node.shortName, 'demo-b');
      await node.logout();
      expect(localApi.logoutCalls, 1);

      await node.close();
      expect(node.isClosed, isTrue);
      expect(native.calls.last, 'close');
      expect(node.status, throwsA(isA<TailscaleClosedException>()));
      await node.close(); // idempotent
      expect(node.start, throwsA(isA<TailscaleClosedException>()));
    },
  );

  test(
    'defaults to the Tailscale control plane and exchanges OAuth clients',
    () async {
      localApi.busLines = [_running];
      native.ips = '100.64.0.1,fd7a::1';
      final exchanger = _FakeExchanger();
      final node = makeNode(
        config(
          credential: const TailscaleCredential.oauthClient(
            clientId: 'k1',
            clientSecret: 'tskey-client-s',
            tags: ['tag:demo'],
          ),
        ),
        oauth: exchanger,
      );
      await node.start();
      expect(exchanger.calls.single.clientId, 'k1');
      expect(native.settings['authKey'], 'tskey-auth-minted');
      expect(
        native.settings['controlUrl'],
        'https://controlplane.tailscale.com',
      );
      await node.waitUntilRunning(timeout: const Duration(seconds: 5));
      await node.close();
    },
  );

  test('existingState fails fast when a login URL appears', () async {
    localApi.busLines = [_starting, _needsLogin];
    final node = makeNode(
      config(credential: const TailscaleCredential.existingState()),
    );
    final urls = <String>[];
    node.authUrls.listen(urls.add);
    await node.start();
    expect(native.settings.containsKey('authKey'), isFalse);
    await expectLater(
      node.waitUntilRunning(timeout: const Duration(seconds: 5)),
      throwsA(
        isA<TailscaleAuthRequiredException>()
            .having((e) => e.state, 'state', BackendState.needsLogin)
            .having((e) => e.authUrl, 'authUrl', contains('mkey:abc')),
      ),
    );
    expect(urls, ['https://headscale.example.com/register/mkey:abc']);
    expect(node.authUrl, urls.single);
    await node.close();
  });

  test('interactive credential keeps waiting and publishes the URL', () async {
    localApi.busLines = [_needsLogin, null, _running];
    final node = makeNode(
      config(credential: const TailscaleCredential.interactive()),
    );
    await node.start();
    final url = await node.authUrls.first.timeout(const Duration(seconds: 5));
    expect(url, contains('register'));
    expect(node.state, BackendState.needsLogin);
    // "Admin" completes registration.
    native.ips = '100.64.0.1,fd7a::1';
    localApi.busGate.complete();
    await node.waitUntilRunning(timeout: const Duration(seconds: 5));
    await node.close();
  });

  test('backend errors fail waitUntilRunning', () async {
    localApi.busLines = [_starting, '{"ErrMessage":"invalid key: expired"}'];
    final node = makeNode(config());
    await node.start();
    await expectLater(
      node.waitUntilRunning(timeout: const Duration(seconds: 5)),
      throwsA(
        isA<TailscaleBackendException>().having(
          (e) => e.message,
          'message',
          contains('expired'),
        ),
      ),
    );
    await node.close();
  });

  test('timeouts carry the last state and health', () async {
    localApi.busLines = [_starting];
    final node = makeNode(config());
    await node.start();
    await expectLater(
      node.waitUntilRunning(timeout: const Duration(milliseconds: 300)),
      throwsA(
        isA<TailscaleTimeoutException>()
            .having((e) => e.lastState, 'lastState', BackendState.starting)
            .having((e) => e.health, 'health', ['Tailscale is starting.']),
      ),
    );
    await node.close();
  });

  test(
    'falls back to status polling when the LocalAPI is unreachable',
    () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      native.loopbackPort = port;
      native.ips = '100.64.0.1,fd7a::1';
      final node = makeNode(config());
      await node.start();
      await node.waitUntilRunning(timeout: const Duration(seconds: 5));
      expect(node.state, BackendState.running);
      expect(native.calls, contains('statusJson'));
      final status = await node.status();
      expect(status.isRunning, isTrue);
      await node.close();
    },
  );

  test('start failures release the handle', () async {
    native.startError = const TailscaleNativeException(
      'tailscale_start',
      -1,
      'boom',
    );
    final node = makeNode(config());
    await expectLater(node.start(), throwsA(isA<TailscaleNativeException>()));
    expect(node.isClosed, isTrue);
    expect(native.calls, contains('close'));
  });

  test('listen accepts tailnet connections through the reactor', () async {
    localApi.busLines = [_running];
    native.ips = '100.64.0.1,fd7a::1';
    final node = makeNode(config());
    await node.start();
    await node.waitUntilRunning();

    final server = await node.listen(port: 7777);
    expect(native.listened, [':7777']);
    final listenerFd = native.listenerPeers.keys.single;
    final accepted = Completer<TailscaleSocket>();
    server.listen(accepted.complete);

    final peer = native.queueConnection(listenerFd);
    final socket = await accepted.future.timeout(const Duration(seconds: 5));
    expect(socket.remoteAddress!.address, '100.64.0.99');

    final received = <int>[];
    final done = Completer<void>();
    socket.listen(received.addAll, onDone: done.complete);
    writeAllBlocking(peer, utf8.encode('hello'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(utf8.decode(received), 'hello');

    socket.write('world');
    await socket.flush();
    expect(utf8.decode(libcRead(peer, 64)), 'world');

    await socket.close();
    expect(libcRead(peer, 64), isEmpty, reason: 'half-close reaches the peer');
    Libc.close(peer);
    await done.future.timeout(const Duration(seconds: 5));
    await socket.done.timeout(const Duration(seconds: 5));

    await server.close();
    expect(server.isClosed, isTrue);
    await node.close();
  });

  test('dial returns a TailscaleSocket over the fd path', () async {
    localApi.busLines = [_running];
    native.ips = '100.64.0.1,fd7a::1';
    final node = makeNode(config());
    await node.start();

    // ignore: close_sinks
    final socket = await node.dial('fd7a:115c:a1e0::2', 22);
    expect(native.dialed, ['[fd7a:115c:a1e0::2]:22']);
    expect(socket.remoteAddress!.address, 'fd7a:115c:a1e0::2');
    expect(socket.remotePort, 22);
    final peer = native.dialPeers[socket.fd]!;
    socket.add(utf8.encode('ssh'));
    await socket.flush();
    expect(utf8.decode(libcRead(peer, 16)), 'ssh');
    await socket.destroy();
    expect(libcRead(peer, 16), isEmpty);
    await node.close();
  });

  test('connect and httpClient go through the loopback SOCKS5 proxy', () async {
    localApi.busLines = [_running];
    native.ips = '100.64.0.1,fd7a::1';
    final node = makeNode(config());
    await node.start();

    final socket = await node.connect('demo-b', 9);
    expect(socks.requests, [('demo-b', 9)]);
    final received = <int>[];
    final done = Completer<void>();
    socket.listen(received.addAll, onDone: done.complete);
    socket.write('x');
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await socket.close();
    await done.future.timeout(const Duration(seconds: 5));
    expect(utf8.decode(received), 'ECHO\nx');

    final client = node.httpClient();
    client.close(force: true);
    await node.close();
  });

  test('captureLogs streams tsnet log lines', () async {
    localApi.busLines = [_running];
    final node = makeNode(config(captureLogs: true));
    final lines = <String>[];
    node.logs.listen(lines.add);
    await node.start();
    expect(native.logFd, greaterThan(2));
    writeAllBlocking(native.logFd, utf8.encode('first line\nsecond'));
    writeAllBlocking(native.logFd, utf8.encode(' line\n'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(lines, ['first line', 'second line']);
    await node.close();
    Libc.close(native.logFd);
  });

  test('enableFunnelToLocalhost is gated on certificate domains', () async {
    localApi.busLines = [_running];
    localApi.statusFixture = 'test/fixtures/status_headscale.json';
    final node = makeNode(config());
    await node.start();
    await expectLater(
      node.enableFunnelToLocalhost(8080),
      throwsA(isA<TailscaleUnsupportedException>()),
    );
    expect(native.calls, isNot(contains('funnel')));
    localApi.statusFixture = 'test/fixtures/status_tailscale.json';
    await node.enableFunnelToLocalhost(8080);
    expect(native.calls, contains('funnel'));
    await node.close();
  });

  test('methods before start throw StateError', () async {
    final node = makeNode(config());
    expect(node.status, throwsStateError);
    expect(() => node.connect('a', 1), throwsStateError);
    expect(() => node.listen(port: 1), throwsStateError);
    await node.close();
  });
}
