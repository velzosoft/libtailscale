// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../ffi/libc.dart';

/// Exported by `lib/src/hook/android_interfaces.go`, which the build hook compiles
/// into the Android library only: sets a variable in the Go runtime's copy of
/// the environment, which is taken when the library loads and is therefore
/// not updated by a later C `setenv(3)`.
@Native<Int Function(Pointer<Utf8>, Pointer<Utf8>, Int)>(
  symbol: 'tailscale_dart_setenv',
  assetId: 'package:libtailscale/src/ffi/tailscale_bindings.g.dart',
)
external int _goSetenv(Pointer<Utf8> name, Pointer<Utf8> value, int overwrite);

/// Environment variables tsnet needs and Android app processes lack.
///
/// tailscale's `logpolicy` looks for a writable place for its log state in
/// `$HOME`/`$XDG_CACHE_HOME`, the working directory and `$TMPDIR`, and panics
/// (taking the whole process down) when none exists. An Android app process
/// starts with none of these variables, its working directory is `/` and
/// Go's fallback temp dir `/data/local/tmp` is not writable by apps.
///
/// Sets `HOME` and `TMPDIR` to [stateDir] when they are missing, both in the
/// C environment and in the Go runtime's copy (see [_goSetenv]), and returns
/// the names it set. Called by `TailscaleNode.start()`. No-op off Android.
List<String> prepareProcessEnvironment(
  String stateDir, {
  bool? isAndroid,
  String? Function(String name) getenv = Libc.getenv,
  void Function(String name, String value) setenv = _setenvKeepExisting,
}) {
  if (!(isAndroid ?? Platform.isAndroid)) return const [];
  final set = <String>[];
  for (final name in const ['HOME', 'TMPDIR']) {
    if ((getenv(name) ?? '').isEmpty) {
      setenv(name, stateDir);
      set.add(name);
    }
  }
  return set;
}

void _setenvKeepExisting(String name, String value) {
  Libc.setenv(name, value, overwrite: false);
  final cName = name.toNativeUtf8();
  final cValue = value.toNativeUtf8();
  try {
    if (_goSetenv(cName, cValue, 0) != 0) {
      throw StateError('tailscale_dart_setenv($name) failed');
    }
  } finally {
    malloc
      ..free(cName)
      ..free(cValue);
  }
}
