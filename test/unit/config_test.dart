// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:libtailscale/libtailscale.dart';
import 'package:test/test.dart';

void main() {
  const authKey = TailscaleCredential.authKey('tskey-auth-abc');
  const base = TailscaleConfig(
    credential: authKey,
    hostname: 'demo',
    stateDir: '/tmp/state',
  );

  test('defaults to the Tailscale control plane', () {
    expect(base.controlUrl, isNull);
    expect(base.effectiveControlUrl.host, 'controlplane.tailscale.com');
    expect(base.isTailscaleControlPlane, isTrue);
    base.validate();
  });

  test('Headscale URL is not the Tailscale control plane', () {
    final hs = base.copyWith(controlUrl: Uri.parse('https://hs.example.com'));
    expect(hs.isTailscaleControlPlane, isFalse);
    hs.validate();
  });

  test('rejects empty hostname and state dir', () {
    expect(() => base.copyWith(hostname: ' ').validate(), throwsArgumentError);
    expect(() => base.copyWith(stateDir: '').validate(), throwsArgumentError);
  });

  test('rejects non-http control URLs', () {
    expect(
      () => base.copyWith(controlUrl: Uri.parse('ftp://x')).validate(),
      throwsArgumentError,
    );
    expect(
      () => base.copyWith(controlUrl: Uri.parse('relative/path')).validate(),
      throwsArgumentError,
    );
  });

  test('rejects OAuth client secrets passed as auth keys', () {
    expect(
      () => base
          .copyWith(
            credential: const TailscaleCredential.authKey('tskey-client-xyz'),
          )
          .validate(),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('oauthClient'),
        ),
      ),
    );
    expect(
      () => base
          .copyWith(credential: const TailscaleCredential.authKey(''))
          .validate(),
      throwsArgumentError,
    );
  });

  group('OAuth credential', () {
    const oauth = TailscaleCredential.oauthClient(
      clientId: 'k123',
      clientSecret: 'tskey-client-secret',
      tags: ['tag:demo'],
    );

    test('is accepted with the Tailscale control plane', () {
      base.copyWith(credential: oauth).validate();
      expect(oauth.requiresTailscaleControlPlane, isTrue);
      expect((oauth as OAuthClientCredential).ephemeral, isTrue);
      expect(oauth.preauthorized, isTrue);
      expect(oauth.reusable, isFalse);
      expect(oauth.tailnet, '-');
    });

    test('is rejected with Headscale', () {
      expect(
        () => base
            .copyWith(
              credential: oauth,
              controlUrl: Uri.parse('https://hs.example.com'),
            )
            .validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Headscale'),
          ),
        ),
      );
    });

    test('requires tag: tags', () {
      expect(
        () => base
            .copyWith(
              credential: const TailscaleCredential.oauthClient(
                clientId: 'a',
                clientSecret: 'b',
                tags: [],
              ),
            )
            .validate(),
        throwsArgumentError,
      );
      expect(
        () => base
            .copyWith(
              credential: const TailscaleCredential.oauthClient(
                clientId: 'a',
                clientSecret: 'b',
                tags: ['demo'],
              ),
            )
            .validate(),
        throwsArgumentError,
      );
    });
  });

  test('existingState and interactive need no validation', () {
    base
        .copyWith(credential: const TailscaleCredential.existingState())
        .validate();
    base
        .copyWith(credential: const TailscaleCredential.interactive())
        .validate();
  });

  test('toString redacts secrets', () {
    expect(base.toString(), isNot(contains('tskey-auth-abc')));
    expect(
      const TailscaleCredential.oauthClient(
        clientId: 'id',
        clientSecret: 'shh',
        tags: ['tag:x'],
      ).toString(),
      isNot(contains('shh')),
    );
  });
}
