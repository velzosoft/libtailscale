// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libtailscale/libtailscale.dart';

import 'chat_service.dart';
import 'connect_form.dart';

/// The app's view of the node lifecycle (coarser than [BackendState]).
enum ConsolePhase {
  /// No node.
  idle,

  /// `start()` was called; waiting for `Running`.
  connecting,

  /// The node is running and has addresses.
  connected,
}

/// Owns the [TailscaleNode] and exposes everything the screens show.
///
/// This is the only place that calls into the library's lifecycle API; the
/// widgets read fields and call [connect], [disconnect], [logout] and
/// [refreshStatus]. Services that operate over the node ([ChatService]) are
/// attached once the node is running and detached before it closes.
final class NodeController extends ChangeNotifier {
  /// Creates a controller.
  ///
  /// [stateRoot] yields the writable directory the per-hostname state
  /// directories live in (`path_provider` in the app, a temp dir in tests).
  /// [createNode] exists so tests can substitute the node.
  NodeController({
    required this.stateRoot,
    this.createNode = TailscaleNode.new,
    ChatService? chat,
    ConnectForm? initialForm,
    this.statusInterval = const Duration(seconds: 3),
    this.runningTimeout = const Duration(seconds: 90),
  }) : chat = chat ?? ChatService(),
       form = initialForm ?? const ConnectForm() {
    unawaited(_checkSavedState());
  }

  /// How often the Node screen's status is refreshed while connected.
  final Duration statusInterval;

  /// First wait for `Running`; afterwards the app keeps waiting in slices and
  /// shows a warning, because interactive logins take as long as they take.
  final Duration runningTimeout;

  /// Chat listener and sender bound to the current node.
  final ChatService chat;

  /// Directory the per-hostname state directories live in.
  final Future<Directory> Function() stateRoot;

  /// Builds the node for a configuration.
  final TailscaleNode Function(TailscaleConfig config) createNode;

  /// The form as currently edited on the Connect screen.
  ConnectForm form;

  /// Lifecycle phase.
  ConsolePhase phase = ConsolePhase.idle;

  /// Why the last connect attempt failed, or a failed logout.
  String? error;

  /// A non-fatal problem while connecting (e.g. still not running).
  String? warning;

  /// Last backend state reported by the node.
  BackendState? backendState;

  /// Current health messages; empty means healthy.
  List<String> health = const [];

  /// Login URL for the interactive credential.
  String? authUrl;

  /// The node's tailnet addresses once running.
  TailscaleAddresses addresses = TailscaleAddresses.empty;

  /// Last full status, refreshed every [statusInterval].
  TailscaleStatus? status;

  /// When [status] was fetched.
  DateTime? statusAt;

  /// Why the last status refresh failed.
  String? statusError;

  /// The state directory of the current or last node.
  String? stateDir;

  /// Whether a state directory with content exists for the form's hostname.
  bool savedStateExists = false;

  /// The node, while one exists.
  TailscaleNode? node;

  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _statusTimer;
  bool _refreshing = false;

  /// Replaces the form (called on every keystroke).
  void updateForm(ConnectForm next) {
    final hostnameChanged = next.hostname.trim() != form.hostname.trim();
    form = next;
    notifyListeners();
    if (hostnameChanged) unawaited(_checkSavedState());
  }

  /// Validates the form, creates the node and waits until it is running.
  Future<void> connect() async {
    if (phase != ConsolePhase.idle) return;
    final problem = form.validate();
    if (problem != null) {
      error = problem;
      notifyListeners();
      return;
    }
    error = null;
    warning = null;
    phase = ConsolePhase.connecting;
    notifyListeners();

    final TailscaleNode node;
    try {
      final dir = await _stateDirFor(form.hostname.trim());
      stateDir = dir;
      node = createNode(form.toConfig(stateDir: dir));
    } catch (e) {
      error = '$e';
      phase = ConsolePhase.idle;
      notifyListeners();
      return;
    }
    this.node = node;
    _subscriptions.addAll([
      node.stateChanges.listen((s) {
        backendState = s;
        notifyListeners();
      }),
      node.health.listen((h) {
        health = h;
        notifyListeners();
      }),
      node.authUrls.listen((url) {
        authUrl = url;
        notifyListeners();
      }),
    ]);
    try {
      await node.start();
      await _waitUntilRunning(node);
      if (!identical(this.node, node)) return; // disconnected meanwhile
      addresses = node.addresses;
      warning = null;
      phase = ConsolePhase.connected;
      notifyListeners();
      await chat.attach(node);
      _statusTimer = Timer.periodic(statusInterval, (_) => refreshStatus());
      await refreshStatus();
    } on TailscaleException catch (e) {
      await _fail(node, e.message);
    } catch (e) {
      await _fail(node, '$e');
    }
  }

  Future<void> _waitUntilRunning(TailscaleNode node) async {
    final started = DateTime.now();
    var slice = runningTimeout;
    while (true) {
      try {
        await node.waitUntilRunning(timeout: slice);
        return;
      } on TailscaleTimeoutException catch (e) {
        if (!identical(this.node, node) || node.isClosed) return;
        final waited = DateTime.now().difference(started).inSeconds;
        final state = e.lastState?.wireName ?? 'unknown';
        final problems = e.health.isEmpty
            ? ''
            : ' Health: ${e.health.join('; ')}.';
        warning =
            'Not running after ${waited}s (state $state).$problems '
            'Still waiting; Disconnect to stop.';
        notifyListeners();
        slice = const Duration(seconds: 30);
      }
    }
  }

  Future<void> _fail(TailscaleNode node, String message) async {
    if (!identical(this.node, node)) return;
    error = message;
    await _teardown();
    notifyListeners();
  }

  /// Closes the node; the identity in the state directory survives.
  Future<void> disconnect() async {
    if (node == null && phase == ConsolePhase.idle) return;
    await _teardown();
    notifyListeners();
  }

  /// Logs the node out of the control server, then closes it. The saved
  /// state can no longer be reused afterwards.
  Future<void> logout() async {
    final current = node;
    if (current == null) return;
    try {
      await current.logout();
    } on TailscaleException catch (e) {
      error = 'Logout failed: ${e.message}';
    } finally {
      await disconnect();
    }
  }

  /// Fetches the node status (self, peers, tailnet, health).
  Future<void> refreshStatus() async {
    final current = node;
    if (current == null || phase != ConsolePhase.connected || _refreshing) {
      return;
    }
    _refreshing = true;
    try {
      status = await current.status();
      statusAt = DateTime.now();
      statusError = null;
      addresses = await current.refreshAddresses();
    } on TailscaleException catch (e) {
      statusError = e.message;
    } catch (e) {
      statusError = '$e';
    } finally {
      _refreshing = false;
    }
    if (identical(node, current)) notifyListeners();
  }

  /// Called when the app returns to the foreground. Userspace WireGuard
  /// stops while a mobile app is suspended; refresh what the screens show
  /// and revive the chat listener if it closed.
  void onAppResumed() {
    if (phase != ConsolePhase.connected) return;
    unawaited(refreshStatus());
    unawaited(chat.ensureListening());
  }

  Future<String> _stateDirFor(String hostname) async {
    final root = await stateRoot();
    return root.uri.resolve('libtailscale/$hostname').toFilePath();
  }

  Future<void> _checkSavedState() async {
    bool exists;
    try {
      final dir = Directory(await _stateDirFor(form.hostname.trim()));
      exists = dir.existsSync() && dir.listSync().isNotEmpty;
    } catch (_) {
      exists = false;
    }
    if (exists != savedStateExists) {
      savedStateExists = exists;
      notifyListeners();
    }
  }

  Future<void> _teardown() async {
    _statusTimer?.cancel();
    _statusTimer = null;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await chat.detach();
    final current = node;
    node = null;
    if (current != null) {
      try {
        await current.close();
      } catch (_) {
        // Closing a node that failed to start can fail too; nothing to do.
      }
    }
    phase = ConsolePhase.idle;
    warning = null;
    backendState = null;
    health = const [];
    authUrl = null;
    addresses = TailscaleAddresses.empty;
    status = null;
    statusAt = null;
    statusError = null;
    unawaited(_checkSavedState());
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    // _teardown() finishes asynchronously after dispose(); stay silent then.
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    chat.dispose();
    super.dispose();
  }
}
