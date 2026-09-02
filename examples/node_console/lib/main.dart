// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Node Console: a Flutter front end for a headless libtailscale node.
///
/// Three screens over one [NodeController]: Connect (control server,
/// credential, hostname), Node (details and peers) and Communicate (chat
/// over TCP, HTTP fetch). The app contains no networking code of its own;
/// every network operation is a call into `package:libtailscale`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/connect_form.dart';
import 'src/node_controller.dart';
import 'src/screens/communicate_screen.dart';
import 'src/screens/connect_screen.dart';
import 'src/screens/node_screen.dart';

void main() {
  final controller = NodeController(
    stateRoot: getApplicationSupportDirectory,
    initialForm: ConnectForm.fromEnvironment(
      defaultHostname: 'node-console-${Platform.operatingSystem}',
    ),
  );
  runApp(
    NodeConsoleApp(
      controller: controller,
      // --dart-define=NODE_CONSOLE_AUTOCONNECT=true connects on launch with
      // the prefilled form (device checklists, CI).
      autoConnect: const bool.fromEnvironment('NODE_CONSOLE_AUTOCONNECT'),
    ),
  );
}

/// The application widget.
class NodeConsoleApp extends StatefulWidget {
  /// Creates the app around [controller].
  const NodeConsoleApp({
    super.key,
    required this.controller,
    this.autoConnect = false,
  });

  /// Owns the node.
  final NodeController controller;

  /// Call `connect()` after the first frame.
  final bool autoConnect;

  @override
  State<NodeConsoleApp> createState() => _NodeConsoleAppState();
}

class _NodeConsoleAppState extends State<NodeConsoleApp>
    with WidgetsBindingObserver {
  late final _ConsoleLogger _logger;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _logger = _ConsoleLogger(widget.controller);
    if (widget.autoConnect) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(widget.controller.connect()),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.controller.onAppResumed();
  }

  @override
  void dispose() {
    _logger.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Node Console',
    theme: ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.light,
    ),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
    ),
    home: HomeShell(controller: widget.controller),
  );
}

/// Navigation between the three screens: a bottom bar on phones, a rail on
/// wide windows. Screens stay alive in an [IndexedStack] so typed text and
/// the chat log survive switching.
class HomeShell extends StatefulWidget {
  /// Creates the shell.
  const HomeShell({super.key, required this.controller});

  /// Shared controller.
  final NodeController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _index = 0;

  static const _titles = ['Connect', 'Node', 'Communicate'];
  static const _icons = [
    Icons.power_settings_new,
    Icons.dns,
    Icons.chat_bubble_outline,
  ];

  @override
  Widget build(BuildContext context) {
    final page = IndexedStack(
      index: _index,
      children: [
        ConnectScreen(controller: widget.controller),
        NodeScreen(controller: widget.controller),
        CommunicateScreen(controller: widget.controller),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        return Scaffold(
          appBar: AppBar(
            title: Text('Node Console · ${_titles[_index]}'),
            actions: [_PhaseChip(controller: widget.controller)],
          ),
          body: wide
              ? Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _index,
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      destinations: [
                        for (var i = 0; i < _titles.length; i++)
                          NavigationRailDestination(
                            icon: Icon(_icons[i]),
                            label: Text(_titles[i]),
                          ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: page),
                  ],
                )
              : page,
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (var i = 0; i < _titles.length; i++)
                      NavigationDestination(
                        icon: Icon(_icons[i]),
                        label: _titles[i],
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _PhaseChip extends StatelessWidget {
  const _PhaseChip({required this.controller});

  final NodeController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final label = switch (controller.phase) {
        ConsolePhase.idle => 'offline',
        ConsolePhase.connecting =>
          controller.backendState?.wireName ?? 'starting',
        ConsolePhase.connected =>
          controller.addresses.ipv4?.address ?? 'running',
      };
      return Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Chip(
          avatar: Icon(
            Icons.circle,
            size: 10,
            color: switch (controller.phase) {
              ConsolePhase.idle => Theme.of(context).colorScheme.outline,
              ConsolePhase.connecting => Colors.orange,
              ConsolePhase.connected => Colors.green,
            },
          ),
          label: Text(label),
          visualDensity: VisualDensity.compact,
        ),
      );
    },
  );
}

/// Writes lifecycle transitions to the debug log so `flutter run` and device
/// checklists can follow the node without looking at the screen.
final class _ConsoleLogger {
  _ConsoleLogger(this.controller) {
    controller.addListener(_onChange);
  }

  final NodeController controller;
  ConsolePhase? _phase;
  BackendStateName? _state;
  String? _error;
  String? _authUrl;

  void _onChange() {
    final c = controller;
    final state = c.backendState?.wireName;
    if (c.phase != _phase || state != _state) {
      _phase = c.phase;
      _state = state;
      final ip = c.addresses.ipv4?.address;
      debugPrint(
        'node-console: phase=${c.phase.name} state=${state ?? '-'}'
        '${ip == null ? '' : ' ipv4=$ip'}',
      );
    }
    if (c.error != _error) {
      _error = c.error;
      if (_error != null) debugPrint('node-console: error: $_error');
    }
    if (c.authUrl != _authUrl) {
      _authUrl = c.authUrl;
      if (_authUrl != null) debugPrint('node-console: login URL: $_authUrl');
    }
  }

  void dispose() => controller.removeListener(_onChange);
}

typedef BackendStateName = String;
