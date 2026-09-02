// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:io';

import 'package:libtailscale/libtailscale.dart';

import 'node_options.dart';

/// Owns a [TailscaleNode] for the duration of one command and narrates what
/// happens on [log] (stderr by default): state transitions, login URLs,
/// health problems and, when verbose, tsnet's own logs.
final class NodeSession {
  /// Creates a session for [options].
  NodeSession(this.options, {IOSink? log}) : _log = log ?? stderr;

  /// The options the node was created from.
  final NodeOptions options;

  final IOSink _log;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// The node. Created lazily so a bad configuration fails before any native
  /// resource is touched.
  late final TailscaleNode node = TailscaleNode(options.config);

  /// Starts the node and waits until it is `Running` with addresses.
  Future<void> start() async {
    _subscriptions
      ..add(node.stateChanges.listen((s) => _log.writeln('state: ${s.name}')))
      ..add(
        node.authUrls.listen(
          (url) => _log
            ..writeln('login URL: $url')
            ..writeln(
              '  (Headscale admins: headscale auth register '
              '--auth-id <id from the URL> --user <user>; before 0.29: '
              'headscale nodes register --user <user> --key <key>)',
            ),
        ),
      )
      ..add(
        node.health.listen((problems) {
          if (problems.isNotEmpty) {
            _log.writeln('health: ${problems.join('; ')}');
          } else if (options.verbose) {
            _log.writeln('health: ok');
          }
        }),
      );
    if (options.verbose) {
      _subscriptions.add(
        node.logs.listen((line) => _log.writeln('tsnet: $line')),
      );
    }
    await node.start();
    await node.waitUntilRunning(timeout: options.timeout);
    final addresses = node.addresses;
    _log.writeln(
      'running: ${addresses.ipv4?.address ?? '-'} ${addresses.ipv6?.address ?? '-'}',
    );
  }

  /// Shuts the node down.
  Future<void> close() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await node.close();
  }

  /// Completes when the process receives SIGINT or SIGTERM.
  ///
  /// Both watchers are cancelled afterwards: a live signal subscription keeps
  /// the VM alive, so leaving one behind would prevent the process from
  /// exiting.
  static Future<ProcessSignal> waitForInterrupt() async {
    final completer = Completer<ProcessSignal>();
    final subscriptions = [
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
        signal.watch().listen((s) {
          if (!completer.isCompleted) completer.complete(s);
        }),
    ];
    try {
      return await completer.future;
    } finally {
      for (final s in subscriptions) {
        await s.cancel();
      }
    }
  }
}
