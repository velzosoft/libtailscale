// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:args/args.dart';
import 'package:libtailscale/libtailscale.dart';

/// Adds the options every command shares to [parser].
void addNodeOptions(ArgParser parser) {
  parser
    ..addOption(
      'control-url',
      valueHelp: 'url',
      help:
          'Control server base URL (Headscale, or a Tailscale test server). '
          'Defaults to the Tailscale control plane.',
    )
    ..addOption(
      'auth-key',
      valueHelp: 'tskey-auth-…',
      help:
          'Tailscale auth key or Headscale pre-auth key. '
          'Defaults to \$TS_AUTHKEY.',
    )
    ..addOption(
      'oauth-client-id',
      help: 'Tailscale OAuth client id; needs --oauth-client-secret and --tag.',
    )
    ..addOption(
      'oauth-client-secret',
      help:
          'Tailscale OAuth client secret. '
          'Defaults to \$TS_OAUTH_CLIENT_SECRET.',
    )
    ..addMultiOption(
      'tag',
      valueHelp: 'tag:name',
      help: 'ACL tag for OAuth-minted keys (repeatable).',
    )
    ..addFlag(
      'interactive',
      negatable: false,
      help:
          'No key: print the login URL and wait for the node to be approved '
          '(on Headscale an admin runs `headscale auth register`).',
    )
    ..addOption('hostname', defaultsTo: 'tsnode', help: 'Node hostname.')
    ..addOption(
      'state-dir',
      valueHelp: 'dir',
      help: 'Where the node key lives. Defaults to ~/.tsnode/<hostname>.',
    )
    ..addFlag(
      'ephemeral',
      negatable: false,
      help: 'Register as an ephemeral node (removed when it disconnects).',
    )
    ..addOption(
      'timeout',
      defaultsTo: '60',
      valueHelp: 'seconds',
      help: 'How long to wait for the node to become Running.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Also print tsnet backend logs and every health change.',
    );
}

/// The node configuration derived from the shared command-line options.
final class NodeOptions {
  /// Creates the options.
  const NodeOptions({
    required this.config,
    required this.timeout,
    required this.verbose,
  });

  /// Parses [args] (from a parser that had [addNodeOptions] applied).
  ///
  /// Throws [ArgumentError] for inconsistent options; commands turn that into
  /// a usage error.
  factory NodeOptions.fromArgs(
    ArgResults args, {
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final hostname = args['hostname'] as String;
    if (hostname.trim().isEmpty) {
      throw ArgumentError('--hostname must not be empty');
    }
    final controlUrl = args['control-url'] as String?;
    final verbose = args['verbose'] as bool;
    final timeoutSeconds = int.tryParse(args['timeout'] as String);
    if (timeoutSeconds == null || timeoutSeconds <= 0) {
      throw ArgumentError('--timeout must be a positive number of seconds');
    }
    final stateDir =
        args['state-dir'] as String? ??
        '${env['HOME'] ?? Directory.systemTemp.path}/.tsnode/$hostname';

    return NodeOptions(
      config: TailscaleConfig(
        controlUrl: controlUrl == null ? null : Uri.parse(controlUrl),
        credential: _credential(args, env),
        hostname: hostname,
        stateDir: stateDir,
        ephemeral: args['ephemeral'] as bool,
        captureLogs: verbose,
      ),
      timeout: Duration(seconds: timeoutSeconds),
      verbose: verbose,
    );
  }

  static TailscaleCredential _credential(
    ArgResults args,
    Map<String, String> env,
  ) {
    final authKey = args['auth-key'] as String? ?? env['TS_AUTHKEY'];
    final clientId = args['oauth-client-id'] as String?;
    final secret =
        args['oauth-client-secret'] as String? ?? env['TS_OAUTH_CLIENT_SECRET'];
    final tags = args['tag'] as List<String>;
    final interactive = args['interactive'] as bool;

    if (authKey != null && authKey.isNotEmpty) {
      if (clientId != null || interactive) {
        throw ArgumentError(
          'use only one of --auth-key, --oauth-client-id, '
          '--interactive',
        );
      }
      return TailscaleCredential.authKey(authKey);
    }
    if (clientId != null) {
      if (secret == null || secret.isEmpty) {
        throw ArgumentError(
          '--oauth-client-id needs --oauth-client-secret '
          '(or \$TS_OAUTH_CLIENT_SECRET)',
        );
      }
      if (tags.isEmpty) {
        throw ArgumentError('--oauth-client-id needs at least one --tag');
      }
      if (interactive) {
        throw ArgumentError('--interactive cannot be combined with OAuth');
      }
      return TailscaleCredential.oauthClient(
        clientId: clientId,
        clientSecret: secret,
        tags: tags,
        ephemeral: args['ephemeral'] as bool,
      );
    }
    if (interactive) return const TailscaleCredential.interactive();
    return const TailscaleCredential.existingState();
  }

  /// The node configuration.
  final TailscaleConfig config;

  /// How long to wait for `Running`.
  final Duration timeout;

  /// Whether to print backend logs.
  final bool verbose;
}
