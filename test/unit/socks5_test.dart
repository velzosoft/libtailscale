// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libtailscale/src/api/exceptions.dart';
import 'package:libtailscale/src/runtime/socks5.dart';
import 'package:test/test.dart';

import '../helpers/fake_socks5_proxy.dart';

Uint8List _successReply({int port = 8080}) =>
    Uint8List.fromList([5, 0, 0, 1, 100, 64, 0, 1, port >> 8, port & 0xFF]);

void main() {
  group('Socks5 codec', () {
    test('greeting', () {
      expect(Socks5.greeting([0]), [5, 1, 0]);
      expect(Socks5.greeting([2, 0]), [5, 2, 2, 0]);
      expect(() => Socks5.greeting([]), throwsArgumentError);
    });

    test('userPassRequest', () {
      expect(Socks5.userPassRequest('tsnet', 'pw'), [
        1,
        5,
        ...utf8.encode('tsnet'),
        2,
        ...utf8.encode('pw'),
      ]);
      expect(() => Socks5.userPassRequest('', 'x'), throwsArgumentError);
    });

    test('connectRequest encodes IPv4, IPv6 and domains', () {
      expect(Socks5.connectRequest('100.64.0.1', 443), [
        5,
        1,
        0,
        1,
        100,
        64,
        0,
        1,
        1,
        0xBB,
      ]);
      final v6 = Socks5.connectRequest('[fd7a::1]', 80);
      expect(v6.sublist(0, 4), [5, 1, 0, 4]);
      expect(v6.length, 4 + 16 + 2);
      expect(v6.sublist(20), [0, 80]);
      expect(Socks5.connectRequest('demo-b', 7777), [
        5,
        1,
        0,
        3,
        6,
        ...utf8.encode('demo-b'),
        7777 >> 8,
        7777 & 0xFF,
      ]);
      expect(() => Socks5.connectRequest('x', 70000), throwsRangeError);
    });

    test('replyMessage', () {
      expect(Socks5.replyMessage(5), 'connection refused');
      expect(Socks5.replyMessage(99), contains('99'));
    });
  });

  group('Socks5Handshake', () {
    test('no-auth flow', () {
      final hs = Socks5Handshake(host: 'demo-b', port: 8080);
      expect(hs.initialRequest, [5, 1, 0]);
      expect(hs.feed([5, 0]), Socks5.connectRequest('demo-b', 8080));
      expect(hs.isComplete, isFalse);
      expect(hs.feed(_successReply()), isEmpty);
      expect(hs.isComplete, isTrue);
      expect(hs.reply!.bindAddress, '100.64.0.1');
      expect(hs.reply!.bindPort, 8080);
      expect(hs.leftover, isEmpty);
    });

    test('username/password flow', () {
      final hs = Socks5Handshake(
        host: '100.64.0.2',
        port: 22,
        username: 'tsnet',
        password: 'secret',
      );
      expect(hs.initialRequest, [5, 2, 2, 0]);
      expect(hs.feed([5, 2]), Socks5.userPassRequest('tsnet', 'secret'));
      expect(hs.feed([1, 0]), Socks5.connectRequest('100.64.0.2', 22));
      hs.feed(_successReply(port: 22));
      expect(hs.isComplete, isTrue);
    });

    test('handles one byte at a time', () {
      final hs = Socks5Handshake(host: 'h', port: 1);
      final bytes = [5, 0, ..._successReply()];
      final out = BytesBuilder();
      for (final b in bytes) {
        out.add(hs.feed([b]));
      }
      expect(out.toBytes(), Socks5.connectRequest('h', 1));
      expect(hs.isComplete, isTrue);
      expect(hs.leftover, isEmpty);
      expect(() => hs.feed([1]), throwsStateError);
    });

    test('keeps bytes that follow the reply as leftover', () {
      final hs = Socks5Handshake(host: 'h', port: 1);
      hs.feed([5, 0]);
      hs.feed([..._successReply(), ...utf8.encode('banner')]);
      expect(hs.isComplete, isTrue);
      expect(utf8.decode(hs.leftover), 'banner');
    });

    test('domain-typed reply', () {
      final hs = Socks5Handshake(host: 'h', port: 1);
      hs.feed([5, 0]);
      hs.feed([5, 0, 0, 3, 4, ...utf8.encode('node'), 0, 80]);
      expect(hs.reply!.bindAddress, 'node');
      expect(hs.reply!.bindPort, 80);
    });

    test('failure reply carries the code', () {
      final hs = Socks5Handshake(host: 'h', port: 1);
      hs.feed([5, 0]);
      expect(
        () => hs.feed([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]),
        throwsA(
          isA<Socks5Exception>()
              .having((e) => e.replyCode, 'replyCode', 5)
              .having((e) => e.message, 'message', contains('refused')),
        ),
      );
    });

    test('protocol errors', () {
      expect(
        () => Socks5Handshake(host: 'h', port: 1).feed([4, 0]),
        throwsA(isA<Socks5Exception>()),
      );
      expect(
        () => Socks5Handshake(host: 'h', port: 1).feed([5, 0xFF]),
        throwsA(isA<Socks5Exception>()),
      );
      expect(
        () => Socks5Handshake(host: 'h', port: 1).feed([5, 2]),
        throwsA(isA<Socks5Exception>()),
        reason: 'server wants auth but we have none',
      );
      final auth = Socks5Handshake(
        host: 'h',
        port: 1,
        username: 'u',
        password: 'p',
      );
      auth.feed([5, 2]);
      expect(() => auth.feed([1, 1]), throwsA(isA<Socks5Exception>()));
      expect(
        () => Socks5Handshake(host: 'h', port: 1, username: 'u'),
        throwsArgumentError,
      );
    });
  });

  group('Socks5Client', () {
    late EchoServer echo;
    late FakeSocks5Proxy proxy;
    late Socks5Client client;

    setUp(() async {
      echo = EchoServer(banner: 'HELLO\n');
      await echo.start();
      proxy = FakeSocks5Proxy(
        username: 'tsnet',
        password: 'secret',
        resolveTarget: (host, port) =>
            Socket.connect(InternetAddress.loopbackIPv4, echo.port),
      );
      await proxy.start();
      client = Socks5Client(
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
        username: 'tsnet',
        password: 'secret',
      );
    });

    tearDown(() async {
      await proxy.close();
      await echo.close();
    });

    test('tunnels bytes both ways and preserves the banner', () async {
      final socket = await client.connect('demo-b', 7777);
      expect(proxy.requests, [('demo-b', 7777)]);
      expect(socket.targetHost, 'demo-b');
      expect(socket.remotePort, 7777);
      expect(() => socket.remoteAddress, throwsA(isA<SocketException>()));

      final received = <int>[];
      final done = Completer<void>();
      socket.listen(received.addAll, onDone: done.complete);
      socket.write('ping');
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await socket.close();
      await done.future.timeout(const Duration(seconds: 5));
      expect(utf8.decode(received), 'HELLO\nping');
    });

    test('IP literal targets expose remoteAddress', () async {
      final socket = await client.connect('100.64.0.5', 80);
      expect(socket.remoteAddress.address, '100.64.0.5');
      socket.destroy();
    });

    test('rejects wrong credentials', () async {
      final bad = Socks5Client(
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
        username: 'tsnet',
        password: 'wrong',
      );
      await expectLater(
        bad.connect('demo-b', 1),
        throwsA(isA<Socks5Exception>()),
      );
    });

    test('surfaces CONNECT failures', () async {
      proxy.replyCode = 4;
      await expectLater(
        client.connect('nowhere', 1),
        throwsA(
          isA<Socks5Exception>().having((e) => e.replyCode, 'replyCode', 4),
        ),
      );
    });

    test('startConnect can be cancelled', () async {
      final task = client.startConnect('demo-b', 1);
      task.cancel();
      await expectLater(task.socket, throwsA(isA<SocketException>()));
    });
  });

  group('Socks5Client with HttpClient', () {
    late HttpServer http;
    late HttpServer https;
    late FakeSocks5Proxy proxy;
    late Socks5Client client;
    final certDir = Directory('test/fixtures/tls');

    setUp(() async {
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((req) {
        req.response
          ..write('plain ${req.uri.path} host=${req.headers.host}')
          ..close();
      });
      final serverContext = SecurityContext()
        ..useCertificateChain('${certDir.path}/localhost.cert.pem')
        ..usePrivateKey('${certDir.path}/localhost.key.pem');
      https = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      https.listen((req) {
        req.response
          ..write('secure ${req.uri.path}')
          ..close();
      });
      proxy = FakeSocks5Proxy(
        resolveTarget: (host, port) => Socket.connect(
          InternetAddress.loopbackIPv4,
          host == 'plain.test' ? http.port : https.port,
        ),
      );
      await proxy.start();
      client = Socks5Client(proxyHost: '127.0.0.1', proxyPort: proxy.port);
    });

    tearDown(() async {
      await proxy.close();
      await http.close(force: true);
      await https.close(force: true);
    });

    HttpClient buildHttpClient(SecurityContext? context) {
      final hc = HttpClient(context: context)..findProxy = (_) => 'DIRECT';
      hc.connectionFactory = (uri, _, _) async => client.startConnect(
        uri.host,
        uri.port,
        upgrade: uri.scheme == 'https'
            ? (s) => s.secure(host: 'localhost', context: context)
            : null,
      );
      return hc;
    }

    test('plain HTTP through the tunnel', () async {
      final hc = buildHttpClient(null);
      final req = await hc.getUrl(
        Uri.parse('http://plain.test:${http.port}/x'),
      );
      final res = await req.close();
      expect(res.statusCode, 200);
      expect(
        await utf8.decodeStream(res),
        startsWith('plain /x host=plain.test'),
      );
      expect(proxy.requests.single, ('plain.test', http.port));
      hc.close(force: true);
    });

    test('HTTPS through the tunnel via Socks5Socket.secure', () async {
      final context = SecurityContext()
        ..setTrustedCertificates('${certDir.path}/localhost.cert.pem');
      final hc = buildHttpClient(context);
      final req = await hc.getUrl(
        Uri.parse('https://secure.test:${https.port}/y'),
      );
      final res = await req.close();
      expect(res.statusCode, 200);
      expect(await utf8.decodeStream(res), 'secure /y');
      hc.close(force: true);
    });

    test('secure() rejects a socket that is already listened to', () async {
      final socket = await client.connect('plain.test', http.port);
      socket.listen((_) {});
      expect(socket.secure, throwsStateError);
      socket.destroy();
    });
  });
}
