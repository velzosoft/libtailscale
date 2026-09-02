// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Regenerates `lib/src/ffi/tailscale_bindings.g.dart` from the upstream
/// `tailscale.h` header using ffigen's Dart API.
///
/// Usage (from `tool/ffigen`):
///
/// ```sh
/// dart run bin/generate.dart [--package-root <dir>] [--header <tailscale.h>]
/// ```
///
/// Only maintainers need to run this, and only when the upstream header
/// changes. The generated file is committed so package consumers never need
/// libclang.
library;

import 'dart:io';

import 'package:ffigen/ffigen.dart';
import 'package:path/path.dart' as p;

const _assetId = 'package:libtailscale/src/ffi/tailscale_bindings.g.dart';

/// The `tailscale_*` functions the Dart layer binds. Everything else in the
/// header (`Tsnet*` re-exports) is intentionally left out.
const _functions = <String>{
  'tailscale_new',
  'tailscale_start',
  'tailscale_up',
  'tailscale_close',
  'tailscale_set_dir',
  'tailscale_set_hostname',
  'tailscale_set_authkey',
  'tailscale_set_control_url',
  'tailscale_set_ephemeral',
  'tailscale_set_logfd',
  'tailscale_getips',
  'tailscale_dial',
  'tailscale_listen',
  'tailscale_getremoteaddr',
  'tailscale_accept',
  'tailscale_loopback',
  'tailscale_status_json',
  'tailscale_enable_funnel_to_localhost_plaintext_http1',
  'tailscale_errmsg',
};

const _preamble = '''
// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause
//
// GENERATED FILE. Do not edit by hand.
// Regenerate with: cd tool/ffigen && dart run bin/generate.dart
//
// Bindings to the `tailscale_*` C API of https://github.com/tailscale/libtailscale
// (tailscale.h). Semantics: 0 = success, -1 = see tailscale_errmsg, positive
// values are errno codes (EBADF: bad handle, ERANGE: buffer too small).

// ignore_for_file: type=lint
''';

void main(List<String> args) {
  var packageRoot = p.normalize(p.join(Directory.current.path, '..', '..'));
  String? header;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--package-root':
        packageRoot = p.normalize(p.absolute(args[++i]));
      case '--header':
        header = p.normalize(p.absolute(args[++i]));
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        exit(64);
    }
  }
  header ??= p.join(packageRoot, 'third_party', 'libtailscale', 'tailscale.h');
  header = p.normalize(header);
  if (!File(header).existsSync()) {
    stderr.writeln('header not found: $header');
    stderr.writeln('Did you run `git submodule update --init`?');
    exit(66);
  }
  final outFile = p.join(
    packageRoot,
    'lib',
    'src',
    'ffi',
    'tailscale_bindings.g.dart',
  );

  FfiGenerator(
    headers: Headers(entryPoints: [Uri.file(header)]),
    functions: Functions(
      include: Declarations.includeSet(_functions),
      // None of these functions call back into Dart, and the short setters
      // are safe as leaf calls. The blocking ones (start/up/dial/accept/
      // status_json/loopback) are run on helper isolates by the Dart layer
      // and are *not* marked leaf so the VM can service the isolate.
      isLeaf: (decl) => const {
        'tailscale_new',
        'tailscale_set_dir',
        'tailscale_set_hostname',
        'tailscale_set_authkey',
        'tailscale_set_control_url',
        'tailscale_set_ephemeral',
        'tailscale_set_logfd',
        'tailscale_getips',
        'tailscale_getremoteaddr',
        'tailscale_errmsg',
      }.contains(decl.originalName),
    ),
    // `tailscale`, `tailscale_conn`, `tailscale_listener` are all `int`.
    typedefs: Typedefs.includeSet(const {
      'tailscale',
      'tailscale_conn',
      'tailscale_listener',
    }),
    output: Output(
      dartFile: Uri.file(outFile),
      style: const NativeExternalBindings(assetId: _assetId),
      preamble: _preamble,
    ),
  ).generate();
  stdout.writeln('wrote $outFile');
}
