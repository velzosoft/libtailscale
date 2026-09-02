// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import 'package:libtailscale/libtailscale.dart';
import 'package:libtailscale/src/runtime/node_events.dart';
import 'package:test/test.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, Object?>;

void main() {
  group('TailscaleStatus', () {
    test('parses a Tailscale status document', () {
      final status = TailscaleStatus.fromJson(
        _fixture('status_tailscale.json'),
      );
      expect(status.backendState, BackendState.running);
      expect(status.isRunning, isTrue);
      expect(status.tailscaleIps, [
        '100.101.102.103',
        'fd7a:115c:a1e0::1234:5678',
      ]);
      expect(status.self!.name, 'demo-a');
      expect(status.self!.magicDnsName, 'demo-a.tail1234.ts.net');
      expect(status.self!.tags, ['tag:demo']);
      expect(status.self!.keyExpiry, DateTime.utc(2027, 3, 1, 10));
      expect(status.self!.lastSeen, isNull, reason: 'zero time');
      expect(status.magicDnsSuffix, 'tail1234.ts.net');
      expect(status.currentTailnet!.name, 'example.com');
      expect(status.supportsCertificates, isTrue);
      expect(status.peers, hasLength(2));

      final b = status.peerByIp('100.101.102.104')!;
      expect(b.name, 'demo-b');
      expect(b.os, 'linux');
      expect(b.online, isTrue);
      expect(b.rxBytes, 1048576);
      expect(b.ipv4, '100.101.102.104');
      expect(b.ipv6, 'fd7a:115c:a1e0::1234:5679');
      expect(b.lastHandshake, DateTime.utc(2026, 9, 2, 9, 58, 30));
      expect(status.userOf(b)!.isTaggedDevices, isTrue);

      final phone = status.peers.firstWhere((p) => p.hostName == 'phone');
      expect(phone.online, isFalse);
      expect(phone.expired, isTrue);
      expect(phone.lastSeen, DateTime.utc(2026, 9, 1, 20));
      expect(phone.ipv6, isNull);
      expect(status.userOf(phone)!.loginName, 'alice@example.com');
      expect(
        status.users[1002]!.profilePicUrl,
        'https://example.com/alice.png',
      );
    });

    test('parses a Headscale NeedsLogin document with nulls', () {
      final status = TailscaleStatus.fromJson(
        _fixture('status_headscale.json'),
      );
      expect(status.backendState, BackendState.needsLogin);
      expect(
        status.authUrl,
        startsWith('https://headscale.example.com/register/'),
      );
      expect(status.tailscaleIps, isEmpty);
      expect(status.peers, isEmpty);
      expect(status.users, isEmpty);
      expect(status.currentTailnet, isNull);
      expect(status.certDomains, isEmpty);
      expect(status.supportsCertificates, isFalse);
      expect(status.health, ['not logged in', 'Tailscale is stopped.']);
      expect(status.magicDnsSuffix, '');
      expect(status.self!.name, 'demo-a', reason: 'falls back to HostName');
    });

    test('ignores unknown keys and tolerates empty objects', () {
      final status = TailscaleStatus.fromJson({
        'Unknown': 1,
        'Peer': {'k': 5},
      });
      expect(status.backendState, isNull);
      expect(status.peers, isEmpty);
      expect(status.backendStateName, '');
    });

    test('converts to a synthetic IpnNotify for polling', () {
      final status = TailscaleStatus.fromJson(
        _fixture('status_headscale.json'),
      );
      final n = StatusPollEventSource.fromStatus(status);
      expect(n.state, BackendState.needsLogin);
      expect(n.browseToUrl, status.authUrl);
      expect(n.health!.map((w) => w.text), status.health);
    });
  });

  test('WhoIsResponse', () {
    final who = WhoIsResponse.fromJson(_fixture('whois.json'));
    expect(who.node.shortName, 'demo-b');
    expect(who.node.stableId, 'nPEER0001');
    expect(who.node.addresses, contains('100.101.102.104/32'));
    expect(who.node.tags, ['tag:demo']);
    expect(who.node.os, 'linux');
    expect(who.node.hostname, 'demo-b');
    expect(who.node.online, isTrue);
    expect(who.userProfile!.loginName, 'tagged-devices');
    expect(who.capMap.keys, ['example.com/cap/chat']);
  });

  group('IpnNotify', () {
    final lines = File('test/fixtures/ipn_bus.ndjson')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => IpnNotify.fromJson(jsonDecode(l) as Map<String, Object?>))
        .toList();

    test('parses state, health, URL, login and errors', () {
      expect(lines[0].state, BackendState.starting);
      expect(lines[0].sessionId, 'abc123');
      final warning = lines[0].health!.single;
      expect(warning.code, 'login-state');
      expect(warning.severity, 'high');
      expect(warning.impactsConnectivity, isTrue);
      expect(warning.toString(), 'You are logged out.');

      expect(lines[1].state, BackendState.needsLogin);
      expect(lines[1].browseToUrl, contains('mkey:'));
      expect(lines[2].loginFinished, isTrue);
      expect(lines[3].state, BackendState.running);
      expect(lines[3].health, isEmpty);
      expect(lines[4].errMessage, 'invalid key: key expired');
      expect(lines[4].state, isNull);
    });
  });

  test('BackendState lookups', () {
    expect(BackendState.fromCode(6), BackendState.running);
    expect(BackendState.fromCode(42), isNull);
    expect(BackendState.fromCode(null), isNull);
    expect(
      BackendState.fromWireName('NeedsMachineAuth'),
      BackendState.needsMachineAuth,
    );
    expect(BackendState.fromWireName('Bogus'), isNull);
    expect(BackendState.needsLogin.needsAuthentication, isTrue);
    expect(BackendState.running.needsAuthentication, isFalse);
    expect(IpnWatchOptions.initialHealthState, 128);
    expect(IpnWatchOptions.nodeDefaults, 2 | 128 | 256);
  });

  test('TailscaleAddresses', () {
    expect(TailscaleAddresses.parse('invalid IP,invalid IP').isEmpty, isTrue);
    expect(TailscaleAddresses.parse('').isEmpty, isTrue);
    final a = TailscaleAddresses.parse('100.64.0.1,fd7a:115c:a1e0::1');
    expect(a.ipv4!.address, '100.64.0.1');
    expect(a.ipv6!.address, 'fd7a:115c:a1e0::1');
    expect(a.all, hasLength(2));
    expect(a, TailscaleAddresses.parse('100.64.0.1,fd7a:115c:a1e0::1'));
    expect(TailscaleAddresses.parse('100.64.0.1').ipv6, isNull);
    expect(TailscaleAddresses.parse('fd7a::1,invalid IP').ipv4, isNull);
  });

  test('LoopbackInfo.parse', () {
    final info = LoopbackInfo.parse(
      '127.0.0.1:54321',
      proxyCredential: 'p' * 32,
      localApiCredential: 'l' * 32,
    );
    expect(info.host, '127.0.0.1');
    expect(info.port, 54321);
    expect(info.address, '127.0.0.1:54321');
    expect(
      LoopbackInfo.parse(
        '[::1]:80',
        proxyCredential: '',
        localApiCredential: '',
      ).host,
      '::1',
    );
    expect(
      () => LoopbackInfo.parse(
        'nonsense',
        proxyCredential: '',
        localApiCredential: '',
      ),
      throwsFormatException,
    );
  });
}
