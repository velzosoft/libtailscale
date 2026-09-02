// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:tsnode/tsnode.dart';

Future<void> main(List<String> args) async {
  final code = await runTsnode(args);
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
