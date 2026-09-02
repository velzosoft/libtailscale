// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:args/args.dart';
import 'package:libtailscale/libtailscale.dart';
import 'package:test/test.dart';
import 'package:tsnode/tsnode.dart';

void main() {
  final parser = ArgParser();
  addNodeOptions(parser);
  const env = {'HOME': '/home/me'};

  NodeOptions parse(
    List<String> args, {
    Map<String, String> environment = env,
  }) => NodeOptions.fromArgs(parser.parse(args), environment: environment);

  test(
    'defaults: Tailscale control plane, existing state, ~/.tsnode/<host>',
    () {
      final o = parse([]);
      expect(o.config.controlUrl, isNull);
      expect(o.config.credential, isA<ExistingStateCredential>());
      expect(o.config.hostname, 'tsnode');
      expect(o.config.stateDir, '/home/me/.tsnode/tsnode');
      expect(o.config.ephemeral, isFalse);
      expect(o.config.captureLogs, isFalse);
      expect(o.timeout, const Duration(seconds: 60));
    },
  );

  test('auth key from flag or environment', () {
    expect(
      parse(['--auth-key', 'tskey-auth-x']).config.credential,
      isA<AuthKeyCredential>().having((c) => c.key, 'key', 'tskey-auth-x'),
    );
    expect(
      parse(
        [],
        environment: {'TS_AUTHKEY': 'tskey-auth-env'},
      ).config.credential,
      isA<AuthKeyCredential>().having((c) => c.key, 'key', 'tskey-auth-env'),
    );
  });

  test('OAuth client needs secret and tags', () {
    final o = parse([
      '--oauth-client-id',
      'k1',
      '--oauth-client-secret',
      's',
      '--tag',
      'tag:a',
      '--tag',
      'tag:b',
      '--ephemeral',
    ]);
    final c = o.config.credential as OAuthClientCredential;
    expect(c.clientId, 'k1');
    expect(c.tags, ['tag:a', 'tag:b']);
    expect(c.ephemeral, isTrue);
    expect(
      () => parse(['--oauth-client-id', 'k1', '--tag', 'tag:a']),
      throwsArgumentError,
    );
    expect(
      () => parse(['--oauth-client-id', 'k1', '--oauth-client-secret', 's']),
      throwsArgumentError,
    );
  });

  test('interactive and conflicting credentials', () {
    expect(
      parse(['--interactive']).config.credential,
      isA<InteractiveCredential>(),
    );
    expect(
      () => parse(['--interactive', '--auth-key', 'k']),
      throwsArgumentError,
    );
  });

  test('control url, hostname, state dir, timeout, verbose', () {
    final o = parse([
      '--control-url',
      'https://hs.example.com',
      '--hostname',
      'demo-a',
      '--state-dir',
      '/var/lib/demo',
      '--timeout',
      '5',
      '-v',
    ]);
    expect(o.config.controlUrl, Uri.parse('https://hs.example.com'));
    expect(o.config.hostname, 'demo-a');
    expect(o.config.stateDir, '/var/lib/demo');
    expect(o.timeout, const Duration(seconds: 5));
    expect(o.verbose, isTrue);
    expect(o.config.captureLogs, isTrue);
    expect(() => parse(['--timeout', 'soon']), throwsArgumentError);
    expect(() => parse(['--hostname', ' ']), throwsArgumentError);
  });

  test('runner knows every command', () {
    final runner = buildRunner();
    expect(
      runner.commands.keys,
      containsAll(['join', 'info', 'peers', 'echo', 'send', 'fetch']),
    );
  });
}
