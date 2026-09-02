// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// `tsnode`: a headless command-line Tailscale node built on
/// `package:libtailscale`'s public API only.
library;

export 'src/cli.dart' show runTsnode, buildRunner;
export 'src/node_options.dart';
export 'src/session.dart';
