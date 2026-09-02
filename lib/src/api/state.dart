// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import '../util/json.dart';

/// The IPN backend state (`ipn.State` in Go).
enum BackendState {
  /// Nothing is known yet.
  noState(0, 'NoState'),

  /// The state directory belongs to another OS user.
  inUseOtherUser(1, 'InUseOtherUser'),

  /// The node has no valid node key and needs a credential or login.
  needsLogin(2, 'NeedsLogin'),

  /// The node is registered but waits for admin approval on the control server.
  needsMachineAuth(3, 'NeedsMachineAuth'),

  /// The node is logged in but not running.
  stopped(4, 'Stopped'),

  /// The node is connecting.
  starting(5, 'Starting'),

  /// The node is connected and usable.
  running(6, 'Running');

  const BackendState(this.code, this.wireName);

  /// Integer value used on the IPN bus.
  final int code;

  /// String value used in `ipnstate.Status.BackendState`.
  final String wireName;

  /// Looks up a state by its IPN bus integer; `null` for unknown values.
  static BackendState? fromCode(int? code) {
    if (code == null) return null;
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }

  /// Looks up a state by its status-JSON name; `null` for unknown values.
  static BackendState? fromWireName(String? name) {
    if (name == null) return null;
    for (final s in values) {
      if (s.wireName == name) return s;
    }
    return null;
  }

  /// Whether the node cannot proceed without external authentication.
  bool get needsAuthentication =>
      this == needsLogin || this == needsMachineAuth;
}

/// Bit flags for `/localapi/v0/watch-ipn-bus?mask=` (`ipn.NotifyWatchOpt`).
abstract final class IpnWatchOptions {
  /// Send engine (wireguard) statistics regularly.
  static const int engineUpdates = 1 << 0;

  /// First message carries the current state, auth URL and session ID.
  static const int initialState = 1 << 1;

  /// First message carries the current prefs.
  static const int initialPrefs = 1 << 2;

  /// First message carries the current netmap.
  static const int initialNetMap = 1 << 3;

  /// First message carries the current health state.
  static const int initialHealthState = 1 << 7;

  /// Rate-limit netmap updates to every few seconds.
  static const int rateLimit = 1 << 8;

  /// What [TailscaleNode] subscribes to: state, health and throttled netmaps.
  static const int nodeDefaults = initialState | initialHealthState | rateLimit;
}

/// A single health warning from `health.State` on the IPN bus.
final class HealthWarning {
  /// Creates a warning.
  const HealthWarning({
    required this.code,
    required this.title,
    required this.text,
    this.severity,
    this.impactsConnectivity = false,
  });

  /// Parses one entry of `Health.Warnings`.
  factory HealthWarning.fromJson(String code, Map<String, Object?> json) =>
      HealthWarning(
        code: asString(json['WarnableCode']) ?? code,
        title: asString(json['Title']) ?? '',
        text: asString(json['Text']) ?? '',
        severity: asString(json['Severity']),
        impactsConnectivity: asBool(json['ImpactsConnectivity']) ?? false,
      );

  /// Stable warning identifier, e.g. `login-state`.
  final String code;

  /// Short title.
  final String title;

  /// Full text.
  final String text;

  /// `high`, `medium` or `low`.
  final String? severity;

  /// Whether the warning means the node cannot reach peers.
  final bool impactsConnectivity;

  @override
  String toString() => text.isNotEmpty ? text : title;
}

/// One message from the IPN bus (`ipn.Notify`).
///
/// Only the fields the node lifecycle needs are typed; everything else stays
/// accessible through [raw]. Unknown keys are ignored so that newer tailscale
/// versions never break parsing.
final class IpnNotify {
  /// Creates a notification.
  const IpnNotify({
    this.version,
    this.sessionId,
    this.errMessage,
    this.loginFinished = false,
    this.state,
    this.browseToUrl,
    this.health,
    this.raw = const {},
  });

  /// Parses a JSON object from the NDJSON bus stream.
  factory IpnNotify.fromJson(Map<String, Object?> json) {
    List<HealthWarning>? health;
    final healthJson = asMap(json['Health']);
    if (healthJson != null) {
      final warnings = asMap(healthJson['Warnings']);
      health = [
        if (warnings != null)
          for (final entry in warnings.entries)
            if (asMap(entry.value) case final w?)
              HealthWarning.fromJson(entry.key, w),
      ];
    }
    return IpnNotify(
      version: asString(json['Version']),
      sessionId: asString(json['SessionID']),
      errMessage: asString(json['ErrMessage']),
      loginFinished: json['LoginFinished'] != null,
      state: BackendState.fromCode(asInt(json['State'])),
      browseToUrl: asString(json['BrowseToURL']),
      health: health,
      raw: json,
    );
  }

  /// Backend version string.
  final String? version;

  /// Bus session identifier.
  final String? sessionId;

  /// Non-null when the backend reports an error.
  final String? errMessage;

  /// Whether this message announces a completed login.
  final bool loginFinished;

  /// New or current backend state, if included.
  final BackendState? state;

  /// Login URL the user (or an admin) must visit, if included.
  final String? browseToUrl;

  /// Current health warnings, if included (empty list = healthy).
  final List<HealthWarning>? health;

  /// The full decoded JSON object.
  final Map<String, Object?> raw;

  @override
  String toString() =>
      'IpnNotify(state: ${state?.name}, '
      'browseToUrl: $browseToUrl, errMessage: $errMessage, '
      'health: ${health?.length})';
}
