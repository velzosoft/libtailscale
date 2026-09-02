// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../session.dart';
import 'node_command.dart';

/// Fetches a URL over the tailnet with the node's HttpClient.
final class FetchCommand extends NodeCommand {
  FetchCommand() {
    argParser
      ..addFlag('body', negatable: false, help: 'Print the response body.')
      ..addFlag(
        'insecure',
        negatable: false,
        help: 'Accept any TLS certificate (self-signed peers).',
      );
  }

  @override
  String get name => 'fetch';

  @override
  String get description =>
      'HTTP GET a tailnet URL (http or https, MagicDNS names allowed) and '
      'print status, headers and body size.';

  @override
  String get invocation => '${super.invocation} <url>';

  @override
  Future<int> runWithNode(NodeSession session) async {
    final rest = argResults!.rest;
    if (rest.length != 1) usageException('expected exactly one <url>');
    final url = Uri.tryParse(rest[0]);
    if (url == null || !url.hasScheme || url.host.isEmpty) {
      usageException('<url> must be an absolute http(s) URL');
    }
    final insecure = argResults!['insecure'] as bool;
    final client = session.node.httpClient(
      onBadCertificate: insecure ? (_, _, _) => true : null,
    );
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      stdout.writeln('HTTP ${response.statusCode} ${response.reasonPhrase}');
      response.headers.forEach(
        (name, values) => stdout.writeln('$name: ${values.join(', ')}'),
      );
      final body = BytesBuilder();
      await for (final chunk in response) {
        body.add(chunk);
      }
      stdout.writeln('(${body.length} bytes)');
      if (argResults!['body'] as bool) {
        stdout.writeln(utf8.decode(body.takeBytes(), allowMalformed: true));
      }
      return response.statusCode < 400 ? 0 : exitFailure;
    } on IOException catch (e) {
      stderr.writeln('error: $e');
      return exitFailure;
    } finally {
      client.close(force: true);
    }
  }
}
