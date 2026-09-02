// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:node_console/main.dart';
import 'package:node_console/src/node_controller.dart';

void main() {
  testWidgets('validates the form before creating a node', (tester) async {
    // Sync I/O only: real async work never completes inside testWidgets.
    final temp = Directory.systemTemp.createTempSync('node-console-test');
    var nodesCreated = 0;
    final controller = NodeController(
      stateRoot: () async => temp,
      createNode: (_) {
        nodesCreated++;
        throw StateError('widget tests have no native library');
      },
    );
    addTearDown(() {
      controller.dispose();
      temp.deleteSync(recursive: true);
    });

    // A tall viewport so the lazy ListView builds the whole form.
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(NodeConsoleApp(controller: controller));
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.byKey(const Key('connect-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pump();
    expect(find.text('Auth key is required.'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(nodesCreated, 0);

    await tester.tap(find.byIcon(Icons.dns));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connect first'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connect first'), findsOneWidget);
  });

  testWidgets('a node that fails to start reports the error and resets', (
    tester,
  ) async {
    // Sync I/O only: real async work never completes inside testWidgets.
    final temp = Directory.systemTemp.createTempSync('node-console-test');
    final controller = NodeController(
      stateRoot: () async => temp,
      createNode: (_) => throw StateError('native library missing'),
    );
    addTearDown(() {
      controller.dispose();
      temp.deleteSync(recursive: true);
    });

    // A tall viewport so the lazy ListView builds the whole form.
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(NodeConsoleApp(controller: controller));
    await tester.enterText(
      find.byKey(const Key('auth-key-field')),
      'tskey-auth-test',
    );
    await tester.tap(find.byKey(const Key('connect-button')));
    // No pumpAndSettle: the focused text field's cursor never settles.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(controller.phase, ConsolePhase.idle);
    expect(find.textContaining('native library missing'), findsOneWidget);
    expect(controller.stateDir, endsWith('/libtailscale/node-console'));
  });
}
