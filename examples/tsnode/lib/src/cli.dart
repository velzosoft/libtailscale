// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:args/command_runner.dart';

import 'commands/echo.dart';
import 'commands/fetch.dart';
import 'commands/info.dart';
import 'commands/join.dart';
import 'commands/peers.dart';
import 'commands/send.dart';

/// Exit code for command-line usage errors (sysexits `EX_USAGE`).
const exitUsage = 64;

/// Builds the `tsnode` command runner.
CommandRunner<int> buildRunner() =>
    CommandRunner<int>(
        'tsnode',
        'A headless Tailscale / Headscale node on the command line.\n\n'
            'Every command starts a node from the given options, waits until it '
            'is Running, does its job and shuts the node down. Reuse --state-dir '
            'to keep the node identity between invocations.',
      )
      ..addCommand(JoinCommand())
      ..addCommand(InfoCommand())
      ..addCommand(PeersCommand())
      ..addCommand(EchoCommand())
      ..addCommand(SendCommand())
      ..addCommand(FetchCommand());

/// Runs `tsnode` with [args] and returns the process exit code.
Future<int> runTsnode(List<String> args) async {
  try {
    return await buildRunner().run(args) ?? 0;
  } on UsageException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln()
      ..writeln(e.usage);
    return exitUsage;
  }
}
