// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:libtailscale/libtailscale.dart';

/// Which control server the node talks to.
enum ControlServerPreset {
  /// The Tailscale control plane; no URL to type.
  tailscale('Tailscale'),

  /// Headscale, a Tailscale test server or any other base URL.
  custom('Headscale / URL');

  const ControlServerPreset(this.label);

  /// Text shown on the segmented button.
  final String label;
}

/// How the node authenticates with the control server.
enum CredentialKind {
  /// A Tailscale auth key or Headscale pre-auth key.
  authKey('Auth key'),

  /// A Tailscale OAuth client that mints a tagged auth key first.
  oauthClient('OAuth client'),

  /// No key: the control server hands back a login URL to approve.
  interactive('Interactive login'),

  /// Reuse the node key already stored for this hostname.
  existingState('Saved state');

  const CredentialKind(this.label);

  /// Text shown in the credential picker.
  final String label;
}

/// Everything the Connect screen collects, as an immutable value.
///
/// Pure Dart: [validate] explains why the form cannot become a node yet and
/// [toConfig] turns it into a [TailscaleConfig]. The screen edits copies; the
/// controller owns the current one.
final class ConnectForm {
  /// Creates a form.
  const ConnectForm({
    this.preset = ControlServerPreset.tailscale,
    this.controlUrl = '',
    this.credentialKind = CredentialKind.authKey,
    this.authKey = '',
    this.oauthClientId = '',
    this.oauthClientSecret = '',
    this.tags = '',
    this.hostname = 'node-console',
    this.ephemeral = true,
  });

  /// Prefills the form from `--dart-define` values so a device or CI run can
  /// start with a known configuration. All are optional:
  ///
  /// `NODE_CONSOLE_CONTROL_URL`, `NODE_CONSOLE_AUTH_KEY`,
  /// `NODE_CONSOLE_OAUTH_CLIENT_ID`, `NODE_CONSOLE_OAUTH_CLIENT_SECRET`,
  /// `NODE_CONSOLE_TAGS`, `NODE_CONSOLE_CREDENTIAL`
  /// (`auth_key`, `oauth`, `interactive` or `existing`),
  /// `NODE_CONSOLE_HOSTNAME`, `NODE_CONSOLE_EPHEMERAL` (`true`/`false`).
  factory ConnectForm.fromEnvironment({
    String defaultHostname = 'node-console',
  }) => ConnectForm.fromDefines(const {
    'control_url': String.fromEnvironment('NODE_CONSOLE_CONTROL_URL'),
    'auth_key': String.fromEnvironment('NODE_CONSOLE_AUTH_KEY'),
    'oauth_client_id': String.fromEnvironment('NODE_CONSOLE_OAUTH_CLIENT_ID'),
    'oauth_client_secret': String.fromEnvironment(
      'NODE_CONSOLE_OAUTH_CLIENT_SECRET',
    ),
    'tags': String.fromEnvironment('NODE_CONSOLE_TAGS'),
    'credential': String.fromEnvironment('NODE_CONSOLE_CREDENTIAL'),
    'hostname': String.fromEnvironment('NODE_CONSOLE_HOSTNAME'),
    'ephemeral': String.fromEnvironment('NODE_CONSOLE_EPHEMERAL'),
  }, defaultHostname: defaultHostname);

  /// Builds a form from a key/value map (the `--dart-define` names without
  /// the `NODE_CONSOLE_` prefix, lower-cased). Empty values mean "unset".
  factory ConnectForm.fromDefines(
    Map<String, String> defines, {
    String defaultHostname = 'node-console',
  }) {
    String value(String key) => (defines[key] ?? '').trim();
    final controlUrl = value('control_url');
    final authKey = value('auth_key');
    final clientId = value('oauth_client_id');
    final kind = switch (value('credential').toLowerCase()) {
      'auth_key' || 'authkey' || 'key' => CredentialKind.authKey,
      'oauth' || 'oauth_client' => CredentialKind.oauthClient,
      'interactive' => CredentialKind.interactive,
      'existing' || 'existing_state' || 'saved' => CredentialKind.existingState,
      _ when authKey.isNotEmpty => CredentialKind.authKey,
      _ when clientId.isNotEmpty => CredentialKind.oauthClient,
      _ => CredentialKind.authKey,
    };
    final hostname = value('hostname');
    final ephemeral = value('ephemeral').toLowerCase();
    return ConnectForm(
      preset: controlUrl.isEmpty
          ? ControlServerPreset.tailscale
          : ControlServerPreset.custom,
      controlUrl: controlUrl,
      credentialKind: kind,
      authKey: authKey,
      oauthClientId: clientId,
      oauthClientSecret: value('oauth_client_secret'),
      tags: value('tags'),
      hostname: hostname.isEmpty ? defaultHostname : hostname,
      ephemeral: ephemeral.isEmpty
          ? true
          : const {'1', 'true', 'yes', 'on'}.contains(ephemeral),
    );
  }

  /// Control-server choice.
  final ControlServerPreset preset;

  /// Base URL for [ControlServerPreset.custom].
  final String controlUrl;

  /// Credential choice.
  final CredentialKind credentialKind;

  /// Auth key / pre-auth key for [CredentialKind.authKey].
  final String authKey;

  /// OAuth client id for [CredentialKind.oauthClient].
  final String oauthClientId;

  /// OAuth client secret for [CredentialKind.oauthClient].
  final String oauthClientSecret;

  /// ACL tags for OAuth-minted keys, separated by commas or whitespace.
  final String tags;

  /// The node's hostname (also names its state directory).
  final String hostname;

  /// Register as an ephemeral node.
  final bool ephemeral;

  /// Tags as a list, empty entries dropped.
  List<String> get tagList => tags
      .split(RegExp(r'[,\s]+'))
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  /// The control URL the node will use, or `null` for Tailscale.
  Uri? get effectiveControlUrl => preset == ControlServerPreset.tailscale
      ? null
      : Uri.tryParse(controlUrl.trim());

  /// Why this form cannot become a node yet, or `null` when it can.
  String? validate() {
    final host = hostname.trim();
    if (host.isEmpty) return 'Hostname is required.';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,62}$').hasMatch(host)) {
      return 'Hostname may only contain letters, digits and hyphens.';
    }
    if (preset == ControlServerPreset.custom) {
      final url = effectiveControlUrl;
      if (url == null ||
          !url.hasScheme ||
          !(url.scheme == 'http' || url.scheme == 'https') ||
          url.host.isEmpty) {
        return 'Control URL must be an http(s) URL, '
            'e.g. https://headscale.example.com.';
      }
    }
    switch (credentialKind) {
      case CredentialKind.authKey:
        if (authKey.trim().isEmpty) return 'Auth key is required.';
      case CredentialKind.oauthClient:
        if (oauthClientId.trim().isEmpty) return 'OAuth client id is required.';
        if (oauthClientSecret.trim().isEmpty) {
          return 'OAuth client secret is required.';
        }
        if (tagList.isEmpty) return 'OAuth clients need at least one tag.';
        if (preset != ControlServerPreset.tailscale) {
          return 'OAuth clients only work with the Tailscale control plane.';
        }
      case CredentialKind.interactive:
      case CredentialKind.existingState:
        break;
    }
    try {
      toConfig(stateDir: '/unused').validate();
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    return null;
  }

  /// The credential described by the form.
  TailscaleCredential get credential => switch (credentialKind) {
    CredentialKind.authKey => TailscaleCredential.authKey(authKey.trim()),
    CredentialKind.oauthClient => TailscaleCredential.oauthClient(
      clientId: oauthClientId.trim(),
      clientSecret: oauthClientSecret.trim(),
      tags: tagList,
      ephemeral: ephemeral,
    ),
    CredentialKind.interactive => const TailscaleCredential.interactive(),
    CredentialKind.existingState => const TailscaleCredential.existingState(),
  };

  /// The node configuration; [stateDir] is where the node key lives.
  TailscaleConfig toConfig({required String stateDir}) => TailscaleConfig(
    controlUrl: effectiveControlUrl,
    credential: credential,
    hostname: hostname.trim(),
    stateDir: stateDir,
    ephemeral: ephemeral,
  );

  /// Copies the form with some fields replaced.
  ConnectForm copyWith({
    ControlServerPreset? preset,
    String? controlUrl,
    CredentialKind? credentialKind,
    String? authKey,
    String? oauthClientId,
    String? oauthClientSecret,
    String? tags,
    String? hostname,
    bool? ephemeral,
  }) => ConnectForm(
    preset: preset ?? this.preset,
    controlUrl: controlUrl ?? this.controlUrl,
    credentialKind: credentialKind ?? this.credentialKind,
    authKey: authKey ?? this.authKey,
    oauthClientId: oauthClientId ?? this.oauthClientId,
    oauthClientSecret: oauthClientSecret ?? this.oauthClientSecret,
    tags: tags ?? this.tags,
    hostname: hostname ?? this.hostname,
    ephemeral: ephemeral ?? this.ephemeral,
  );
}
