// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:meta/meta.dart';

/// The Tailscale SaaS control plane.
final tailscaleControlUrl = Uri.parse('https://controlplane.tailscale.com');

/// The Tailscale public API, used for the OAuth client credential exchange.
final tailscaleApiUrl = Uri.parse('https://api.tailscale.com');

/// How the node authenticates with the control server.
///
/// Exactly one credential is supplied per [TailscaleConfig]. The library never
/// shows UI; with [TailscaleCredential.interactive] it only publishes the
/// login URL and leaves everything else to the host application.
@immutable
sealed class TailscaleCredential {
  const TailscaleCredential._();

  /// A Tailscale auth key (`tskey-auth-…`) or a Headscale pre-auth key.
  ///
  /// Reusable / ephemeral / tags are properties of the key itself, decided
  /// when it was created.
  const factory TailscaleCredential.authKey(String key) = AuthKeyCredential;

  /// A Tailscale OAuth client (id + secret). Tailscale control plane only.
  ///
  /// The library exchanges the client credentials for a single-use auth key
  /// through the Tailscale API before starting the node, because libtailscale
  /// cannot set the `AdvertiseTags` that tsnet's built-in OAuth path needs.
  /// [tags] must be non-empty: keys minted by OAuth clients are always tagged.
  const factory TailscaleCredential.oauthClient({
    required String clientId,
    required String clientSecret,
    required List<String> tags,
    bool ephemeral,
    bool preauthorized,
    bool reusable,
    Duration keyExpiry,
    String tailnet,
    Uri? apiBaseUrl,
  }) = OAuthClientCredential;

  /// No credential: rely on the node key persisted in `stateDir` by a
  /// previous run. If it is missing or expired the node lands in
  /// `NeedsLogin` and `waitUntilRunning` fails with
  /// `TailscaleAuthRequiredException`.
  const factory TailscaleCredential.existingState() = ExistingStateCredential;

  /// Interactive login: the node requests a login URL from the control server
  /// and the library publishes it on `TailscaleNode.authUrls`. What the app
  /// does with the URL is its business. On Headscale an administrator approves
  /// the node with `headscale auth register --auth-id ID --user USER`, where
  /// `ID` is the last path segment of the URL (Headscale before 0.29 used
  /// `headscale nodes register --key`).
  const factory TailscaleCredential.interactive() = InteractiveCredential;

  /// Whether this credential only works with the Tailscale control plane.
  bool get requiresTailscaleControlPlane => false;
}

/// See [TailscaleCredential.authKey].
final class AuthKeyCredential extends TailscaleCredential {
  /// Creates the credential.
  const AuthKeyCredential(this.key) : super._();

  /// The auth key / pre-auth key.
  final String key;

  @override
  String toString() => 'TailscaleCredential.authKey(<redacted>)';
}

/// See [TailscaleCredential.oauthClient].
final class OAuthClientCredential extends TailscaleCredential {
  /// Creates the credential.
  const OAuthClientCredential({
    required this.clientId,
    required this.clientSecret,
    required this.tags,
    this.ephemeral = true,
    this.preauthorized = true,
    this.reusable = false,
    this.keyExpiry = const Duration(minutes: 5),
    this.tailnet = '-',
    this.apiBaseUrl,
  }) : super._();

  /// OAuth client ID.
  final String clientId;

  /// OAuth client secret (`tskey-client-…`).
  final String clientSecret;

  /// Tags the minted auth key (and therefore the node) carries.
  final List<String> tags;

  /// Whether nodes created with the key are removed when they go offline.
  final bool ephemeral;

  /// Whether nodes are pre-authorized (no admin approval needed).
  final bool preauthorized;

  /// Whether the minted key may register more than one node.
  final bool reusable;

  /// Lifetime of the minted key; it only needs to survive `start()`.
  final Duration keyExpiry;

  /// Tailnet identifier for the API path; `-` means the client's tailnet.
  final String tailnet;

  /// Override for the Tailscale API base URL (defaults to [tailscaleApiUrl]).
  final Uri? apiBaseUrl;

  @override
  bool get requiresTailscaleControlPlane => true;

  @override
  String toString() =>
      'TailscaleCredential.oauthClient(clientId: $clientId, tags: $tags)';
}

/// See [TailscaleCredential.existingState].
final class ExistingStateCredential extends TailscaleCredential {
  /// Creates the credential.
  const ExistingStateCredential() : super._();

  @override
  String toString() => 'TailscaleCredential.existingState()';
}

/// See [TailscaleCredential.interactive].
final class InteractiveCredential extends TailscaleCredential {
  /// Creates the credential.
  const InteractiveCredential() : super._();

  @override
  String toString() => 'TailscaleCredential.interactive()';
}

/// Configuration for a [TailscaleNode].
@immutable
final class TailscaleConfig {
  /// Creates a configuration.
  ///
  /// [hostname] and [stateDir] are required on purpose: tsnet's defaults
  /// (executable basename, `$UserConfigDir/tsnet-<exe>`) are meaningless
  /// inside a Dart VM or a Flutter app.
  const TailscaleConfig({
    required this.credential,
    required this.hostname,
    required this.stateDir,
    this.controlUrl,
    this.ephemeral = false,
    this.captureLogs = false,
  });

  /// Control server base URL; `null` means the Tailscale control plane.
  ///
  /// For Headscale pass the server's base URL, e.g.
  /// `https://headscale.example.com`.
  final Uri? controlUrl;

  /// How to authenticate.
  final TailscaleCredential credential;

  /// Node hostname (becomes the MagicDNS name).
  final String hostname;

  /// Directory where the node key and other state are persisted.
  ///
  /// Must be writable and unique per node instance.
  final String stateDir;

  /// Register as an ephemeral node (removed from the tailnet when it
  /// disconnects). Only honoured by Headscale / the control plane if the key
  /// allows it; combine with an ephemeral key for predictable behaviour.
  final bool ephemeral;

  /// Capture tsnet backend logs on `TailscaleNode.logs`. Off by default
  /// because the logs are verbose.
  final bool captureLogs;

  /// The effective control URL.
  Uri get effectiveControlUrl => controlUrl ?? tailscaleControlUrl;

  /// Whether the control server is the Tailscale SaaS control plane.
  bool get isTailscaleControlPlane {
    final host = effectiveControlUrl.host.toLowerCase();
    return host == 'controlplane.tailscale.com' ||
        host.endsWith('.tailscale.com');
  }

  /// Validates the configuration, throwing [ArgumentError] on problems.
  ///
  /// Called by `TailscaleNode` before touching native code, so that mistakes
  /// surface as ordinary Dart errors rather than as a node stuck in
  /// `Starting`.
  void validate() {
    if (hostname.trim().isEmpty) {
      throw ArgumentError.value(hostname, 'hostname', 'must not be empty');
    }
    if (stateDir.trim().isEmpty) {
      throw ArgumentError.value(stateDir, 'stateDir', 'must not be empty');
    }
    final url = controlUrl;
    if (url != null) {
      if (!url.isAbsolute || (url.scheme != 'http' && url.scheme != 'https')) {
        throw ArgumentError.value(
          url,
          'controlUrl',
          'must be an absolute http(s) URL',
        );
      }
    }
    switch (credential) {
      case AuthKeyCredential(:final key):
        if (key.trim().isEmpty) {
          throw ArgumentError.value(key, 'credential.key', 'must not be empty');
        }
        if (key.startsWith('tskey-client-')) {
          throw ArgumentError.value(
            '<redacted>',
            'credential.key',
            'looks like an OAuth client secret; use '
                'TailscaleCredential.oauthClient instead',
          );
        }
      case final OAuthClientCredential oauth:
        final OAuthClientCredential(:clientId, :clientSecret, :tags) = oauth;
        if (clientId.isEmpty || clientSecret.isEmpty) {
          throw ArgumentError('OAuth client id and secret must not be empty');
        }
        if (tags.isEmpty || tags.any((t) => !t.startsWith('tag:'))) {
          throw ArgumentError.value(
            tags,
            'credential.tags',
            'OAuth-minted keys must carry at least one "tag:…" tag',
          );
        }
        if (!isTailscaleControlPlane && oauth.apiBaseUrl == null) {
          throw ArgumentError(
            'TailscaleCredential.oauthClient only works with the Tailscale '
            'control plane; Headscale has no OAuth client API. Use a '
            'pre-auth key instead.',
          );
        }
      case ExistingStateCredential():
      case InteractiveCredential():
        break;
    }
  }

  /// Returns a copy with the given fields replaced.
  TailscaleConfig copyWith({
    Uri? controlUrl,
    TailscaleCredential? credential,
    String? hostname,
    String? stateDir,
    bool? ephemeral,
    bool? captureLogs,
  }) => TailscaleConfig(
    controlUrl: controlUrl ?? this.controlUrl,
    credential: credential ?? this.credential,
    hostname: hostname ?? this.hostname,
    stateDir: stateDir ?? this.stateDir,
    ephemeral: ephemeral ?? this.ephemeral,
    captureLogs: captureLogs ?? this.captureLogs,
  );

  @override
  String toString() =>
      'TailscaleConfig(controlUrl: $effectiveControlUrl, '
      'credential: $credential, hostname: $hostname, stateDir: $stateDir, '
      'ephemeral: $ephemeral)';
}
