// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'package:libtailscale/src/runtime/process_environment.dart';
import 'package:test/test.dart';

void main() {
  group('prepareProcessEnvironment', () {
    test('sets HOME and TMPDIR on Android when they are missing', () {
      final env = <String, String>{'TMPDIR': ''};
      final set = prepareProcessEnvironment(
        '/data/user/0/app/files/ts',
        isAndroid: true,
        getenv: (name) => env[name],
        setenv: (name, value) => env[name] = value,
      );
      expect(set, ['HOME', 'TMPDIR']);
      expect(env, {
        'HOME': '/data/user/0/app/files/ts',
        'TMPDIR': '/data/user/0/app/files/ts',
      });
    });

    test('keeps existing values', () {
      final env = <String, String>{'HOME': '/home/x', 'TMPDIR': '/tmp'};
      final set = prepareProcessEnvironment(
        '/state',
        isAndroid: true,
        getenv: (name) => env[name],
        setenv: (name, value) => fail('must not overwrite $name'),
      );
      expect(set, isEmpty);
    });

    test('does nothing off Android', () {
      final set = prepareProcessEnvironment(
        '/state',
        isAndroid: false,
        getenv: (name) => null,
        setenv: (name, value) => fail('must not touch the environment'),
      );
      expect(set, isEmpty);
    });
  });
}
