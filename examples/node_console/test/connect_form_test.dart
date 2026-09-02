// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';
import 'package:libtailscale/libtailscale.dart';
import 'package:node_console/src/connect_form.dart';

void main() {
  group('ConnectForm', () {
    test(
      'defaults to Tailscale with an auth key and reports the missing key',
      () {
        const form = ConnectForm();
        expect(form.preset, ControlServerPreset.tailscale);
        expect(form.credentialKind, CredentialKind.authKey);
        expect(form.effectiveControlUrl, isNull);
        expect(form.validate(), 'Auth key is required.');
      },
    );

    test('an auth key form becomes a Tailscale config', () {
      const form = ConnectForm(
        authKey: ' tskey-auth-abc ',
        hostname: 'demo',
        ephemeral: false,
      );
      expect(form.validate(), isNull);
      final config = form.toConfig(stateDir: '/tmp/state');
      expect(config.controlUrl, isNull);
      expect(config.isTailscaleControlPlane, isTrue);
      expect(
        config.credential,
        isA<AuthKeyCredential>().having((c) => c.key, 'key', 'tskey-auth-abc'),
      );
      expect(config.hostname, 'demo');
      expect(config.stateDir, '/tmp/state');
      expect(config.ephemeral, isFalse);
    });

    test('the custom preset needs a valid http(s) URL', () {
      const form = ConnectForm(
        preset: ControlServerPreset.custom,
        authKey: 'k',
      );
      expect(form.validate(), contains('Control URL'));
      expect(
        form.copyWith(controlUrl: 'headscale.example.com').validate(),
        contains('Control URL'),
      );
      expect(
        form.copyWith(controlUrl: 'ftp://headscale.example.com').validate(),
        contains('Control URL'),
      );
      final ok = form.copyWith(controlUrl: ' https://hs.example.com ');
      expect(ok.validate(), isNull);
      expect(
        ok.toConfig(stateDir: '/s').controlUrl,
        Uri.parse('https://hs.example.com'),
      );
      expect(
        form.copyWith(controlUrl: 'http://127.0.0.1:41641').validate(),
        isNull,
        reason: 'plain http is fine for test servers',
      );
    });

    test('hostnames are required and restricted to DNS labels', () {
      expect(
        const ConnectForm(authKey: 'k', hostname: ' ').validate(),
        'Hostname is required.',
      );
      expect(
        const ConnectForm(authKey: 'k', hostname: 'bad host').validate(),
        contains('letters, digits and hyphens'),
      );
      expect(
        const ConnectForm(
          authKey: 'k',
          hostname: 'node-console-ios',
        ).validate(),
        isNull,
      );
    });

    test('OAuth clients need id, secret, tags and Tailscale', () {
      const form = ConnectForm(credentialKind: CredentialKind.oauthClient);
      expect(form.validate(), 'OAuth client id is required.');
      expect(
        form.copyWith(oauthClientId: 'id').validate(),
        'OAuth client secret is required.',
      );
      final noTags = form.copyWith(
        oauthClientId: 'id',
        oauthClientSecret: 'secret',
      );
      expect(noTags.validate(), 'OAuth clients need at least one tag.');
      final complete = noTags.copyWith(tags: 'tag:a, tag:b tag:c');
      expect(complete.tagList, ['tag:a', 'tag:b', 'tag:c']);
      expect(complete.validate(), isNull);
      expect(
        complete.toConfig(stateDir: '/s').credential,
        isA<OAuthClientCredential>()
            .having((c) => c.clientId, 'clientId', 'id')
            .having((c) => c.clientSecret, 'clientSecret', 'secret')
            .having((c) => c.tags, 'tags', ['tag:a', 'tag:b', 'tag:c'])
            .having((c) => c.ephemeral, 'ephemeral', isTrue),
      );
      expect(
        complete
            .copyWith(
              preset: ControlServerPreset.custom,
              controlUrl: 'https://hs.example.com',
            )
            .validate(),
        'OAuth clients only work with the Tailscale control plane.',
      );
    });

    test('interactive and saved-state credentials need no secret', () {
      const interactive = ConnectForm(
        credentialKind: CredentialKind.interactive,
      );
      expect(interactive.validate(), isNull);
      expect(
        interactive.toConfig(stateDir: '/s').credential,
        isA<InteractiveCredential>(),
      );
      const saved = ConnectForm(credentialKind: CredentialKind.existingState);
      expect(saved.validate(), isNull);
      expect(
        saved.toConfig(stateDir: '/s').credential,
        isA<ExistingStateCredential>(),
      );
    });

    test('fromDefines maps values and infers the credential kind', () {
      final headscale = ConnectForm.fromDefines({
        'control_url': 'http://127.0.0.1:1234',
        'auth_key': 'k',
      });
      expect(headscale.preset, ControlServerPreset.custom);
      expect(headscale.controlUrl, 'http://127.0.0.1:1234');
      expect(headscale.credentialKind, CredentialKind.authKey);
      expect(headscale.ephemeral, isTrue);

      final oauth = ConnectForm.fromDefines({
        'oauth_client_id': 'id',
        'oauth_client_secret': 's',
        'tags': 'tag:x',
      });
      expect(oauth.credentialKind, CredentialKind.oauthClient);
      expect(oauth.preset, ControlServerPreset.tailscale);

      final interactive = ConnectForm.fromDefines({
        'credential': 'interactive',
        'hostname': 'phone',
        'ephemeral': 'false',
      });
      expect(interactive.credentialKind, CredentialKind.interactive);
      expect(interactive.hostname, 'phone');
      expect(interactive.ephemeral, isFalse);

      final saved = ConnectForm.fromDefines({'credential': 'existing'});
      expect(saved.credentialKind, CredentialKind.existingState);

      final empty = ConnectForm.fromDefines(const {}, defaultHostname: 'd');
      expect(empty.hostname, 'd');
      expect(empty.credentialKind, CredentialKind.authKey);
    });
  });
}
