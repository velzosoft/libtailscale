// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import '../api/config.dart';
import '../api/exceptions.dart';
import '../api/state.dart';
import '../api/status.dart';
import 'local_api.dart';

/// Where a node learns about backend state changes.
abstract interface class NodeEventSource {
  /// A stream of notifications. Cancelling the subscription stops the source.
  Stream<IpnNotify> events();
}

/// Streams `watch-ipn-bus` events from the LocalAPI (the primary source).
final class LocalApiEventSource implements NodeEventSource {
  /// Creates the source.
  const LocalApiEventSource(
    this.client, {
    this.mask = IpnWatchOptions.nodeDefaults,
  });

  /// The LocalAPI client.
  final LocalApiClient client;

  /// `NotifyWatchOpt` mask.
  final int mask;

  @override
  Stream<IpnNotify> events() => client.watchIpnBus(mask: mask);
}

/// Polls a status provider and synthesises [IpnNotify] messages from it.
///
/// Used as a fallback when the loopback LocalAPI is unavailable (upstream
/// reports the listener can go stale after an iOS suspend); the provider is
/// then `tailscale_status_json`, which uses tsnet's in-memory LocalAPI.
final class StatusPollEventSource implements NodeEventSource {
  /// Creates the source.
  const StatusPollEventSource(
    this.fetchStatus, {
    this.interval = const Duration(seconds: 2),
  });

  /// Fetches the current status.
  final Future<TailscaleStatus> Function() fetchStatus;

  /// Delay between polls.
  final Duration interval;

  @override
  Stream<IpnNotify> events() {
    // ignore: close_sinks, a poll stream ends only when cancelled
    late final StreamController<IpnNotify> controller;
    Timer? timer;
    var cancelled = false;

    Future<void> poll() async {
      try {
        final status = await fetchStatus();
        if (!cancelled) controller.add(fromStatus(status));
      } catch (e, st) {
        if (!cancelled) controller.addError(e, st);
      } finally {
        if (!cancelled) timer = Timer(interval, poll);
      }
    }

    controller = StreamController<IpnNotify>(
      onListen: poll,
      onCancel: () {
        cancelled = true;
        timer?.cancel();
      },
    );
    return controller.stream;
  }

  /// Converts a status document into the equivalent bus notification.
  static IpnNotify fromStatus(TailscaleStatus status) => IpnNotify(
    state: status.backendState,
    browseToUrl: status.authUrl.isEmpty ? null : status.authUrl,
    health: [
      for (final text in status.health)
        HealthWarning(code: 'status', title: text, text: text),
    ],
    raw: status.raw,
  );
}

/// Tracks the backend state from a stream of [IpnNotify] messages and
/// implements the "wait until running" policy.
///
/// Pure Dart: tests drive it with hand-made notifications.
final class NodeStateTracker {
  /// Creates a tracker for a node using [credential].
  NodeStateTracker({required this.credential});

  /// The credential in use; it decides whether `NeedsLogin` is fatal.
  final TailscaleCredential credential;

  final _notifications = StreamController<IpnNotify>.broadcast();
  final _states = StreamController<BackendState>.broadcast();
  final _health = StreamController<List<String>>.broadcast();
  final _authUrls = StreamController<String>.broadcast();

  BackendState? _state;
  List<String> _healthMessages = const [];
  String? _authUrl;
  Object? _fatal;
  bool _disposed = false;

  /// Last known backend state.
  BackendState? get state => _state;

  /// Last known health messages (empty means healthy).
  List<String> get health => _healthMessages;

  /// Last login URL published by the control server.
  String? get authUrl => _authUrl;

  /// Every notification, after bookkeeping.
  Stream<IpnNotify> get notifications => _notifications.stream;

  /// Distinct backend state changes.
  Stream<BackendState> get stateChanges => _states.stream;

  /// Health message changes.
  Stream<List<String>> get healthChanges => _health.stream;

  /// Login URLs, each distinct URL once.
  Stream<String> get authUrls => _authUrls.stream;

  /// Applies [notify].
  void handle(IpnNotify notify) {
    if (_disposed) return;
    final state = notify.state;
    if (state != null && state != _state) {
      _state = state;
      _states.add(state);
    }
    final health = notify.health;
    if (health != null) {
      final messages = [for (final w in health) w.toString()];
      if (!_sameList(messages, _healthMessages)) {
        _healthMessages = messages;
        _health.add(messages);
      }
    }
    final url = notify.browseToUrl;
    if (url != null && url.isNotEmpty && url != _authUrl) {
      _authUrl = url;
      _authUrls.add(url);
    }
    _fatal ??= _fatalFor(notify);
    _notifications.add(notify);
  }

  /// Records a transport error from the event source (not fatal by itself).
  void handleError(Object error, [StackTrace? stackTrace]) {
    if (_disposed) return;
    _notifications.addError(error, stackTrace ?? StackTrace.current);
  }

  Object? _fatalFor(IpnNotify notify) {
    if (notify.errMessage case final message?) {
      return TailscaleBackendException(message, state: _state);
    }
    if (_state == BackendState.inUseOtherUser) {
      return const TailscaleBackendException(
        'the state directory is in use by another user',
        state: BackendState.inUseOtherUser,
      );
    }
    // A login URL with a credential that cannot act on it is definitive.
    // With an auth key, tsnet may briefly report NeedsLogin (and even request
    // a URL) before the key is applied, so that case is left to the timeout.
    if (credential is ExistingStateCredential &&
        _state == BackendState.needsLogin &&
        _authUrl != null) {
      return TailscaleAuthRequiredException(
        BackendState.needsLogin,
        authUrl: _authUrl,
      );
    }
    return null;
  }

  /// Completes when the state is `Running` and [isUsable] returns true (the
  /// node has addresses), or fails on a fatal backend event or [timeout].
  Future<void> waitUntilRunning({
    required Duration timeout,
    required Future<bool> Function() isUsable,
    Duration recheckInterval = const Duration(milliseconds: 500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final wake = StreamController<void>.broadcast();
    final subscription = notifications.listen(
      (_) => wake.add(null),
      onError: (Object _) => wake.add(null),
    );
    try {
      while (true) {
        if (_fatal case final error?) throw error;
        if (_state == BackendState.running && await isUsable()) return;
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw TailscaleTimeoutException(
            timeout,
            lastState: _state,
            health: [
              ..._healthMessages,
              if (_authUrl != null) 'login URL: $_authUrl',
            ],
          );
        }
        final wait = remaining < recheckInterval ? remaining : recheckInterval;
        await wake.stream.first.timeout(wait, onTimeout: () {});
      }
    } finally {
      await subscription.cancel();
      await wake.close();
    }
  }

  /// Closes all streams.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait([
      _notifications.close(),
      _states.close(),
      _health.close(),
      _authUrls.close(),
    ]);
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
