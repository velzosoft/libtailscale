// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:libtailscale/libtailscale.dart';

import '../node_options.dart';
import '../session.dart';

/// Exit code when the node or the tailnet operation failed.
const exitFailure = 2;

/// Base class for commands that need a running node.
///
/// Parses the shared options, starts the node, runs [runWithNode] and always
/// closes the node afterwards. Tailscale errors become a message on stderr
/// and [exitFailure].
abstract class NodeCommand extends Command<int> {
  /// Creates the command and registers the shared node options.
  NodeCommand() {
    addNodeOptions(argParser);
  }

  /// Runs the command's own logic against the started node.
  Future<int> runWithNode(NodeSession session);

  @override
  Future<int> run() async {
    final NodeOptions options;
    try {
      options = NodeOptions.fromArgs(argResults!);
    } on ArgumentError catch (e) {
      usageException(e.message.toString());
    }
    final session = NodeSession(options);
    try {
      await session.start();
      return await runWithNode(session);
    } on TailscaleTimeoutException catch (e) {
      stderr
        ..writeln('error: $e')
        ..writeln(
          'hints: check --control-url, the key, and that the node is '
          'approved on the control server.',
        );
      return exitFailure;
    } on TailscaleException catch (e) {
      stderr.writeln('error: $e');
      return exitFailure;
    } on ArgumentError catch (e) {
      stderr.writeln('error: ${e.message}');
      return exitFailure;
    } finally {
      await session.close();
    }
  }
}
