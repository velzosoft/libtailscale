// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io' show InternetAddress, InternetAddressType;

/// The tailnet addresses assigned to this node.
final class TailscaleAddresses {
  /// Creates an address pair.
  const TailscaleAddresses({this.ipv4, this.ipv6});

  /// No addresses (the node is not running yet).
  static const empty = TailscaleAddresses();

  /// Parses the `<ip4>,<ip6>` string produced by `tailscale_getips`.
  ///
  /// Before the node is running, tsnet renders zero addresses as
  /// `invalid IP`; those (and anything else unparsable) are dropped.
  factory TailscaleAddresses.parse(String raw) {
    InternetAddress? v4;
    InternetAddress? v6;
    for (final part in raw.split(',')) {
      final addr = InternetAddress.tryParse(part.trim());
      if (addr == null) continue;
      if (addr.type == InternetAddressType.IPv4) {
        v4 ??= addr;
      } else if (addr.type == InternetAddressType.IPv6) {
        v6 ??= addr;
      }
    }
    return TailscaleAddresses(ipv4: v4, ipv6: v6);
  }

  /// The node's IPv4 address (`100.x.y.z`), if assigned.
  final InternetAddress? ipv4;

  /// The node's IPv6 address (`fd7a:115c:a1e0::…`), if assigned.
  final InternetAddress? ipv6;

  /// Whether no address is assigned yet.
  bool get isEmpty => ipv4 == null && ipv6 == null;

  /// Whether at least one address is assigned.
  bool get isNotEmpty => !isEmpty;

  /// Both addresses, IPv4 first.
  List<InternetAddress> get all => [?ipv4, ?ipv6];

  @override
  bool operator ==(Object other) =>
      other is TailscaleAddresses && other.ipv4 == ipv4 && other.ipv6 == ipv6;

  @override
  int get hashCode => Object.hash(ipv4, ipv6);

  @override
  String toString() =>
      'TailscaleAddresses(${ipv4?.address ?? '-'}, ${ipv6?.address ?? '-'})';
}
