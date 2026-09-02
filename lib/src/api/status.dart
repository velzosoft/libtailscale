// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import '../util/json.dart';
import 'state.dart';

/// A user profile (`tailcfg.UserProfile`).
final class UserProfile {
  /// Creates a profile.
  const UserProfile({
    required this.id,
    required this.loginName,
    required this.displayName,
    this.profilePicUrl,
  });

  /// Parses a `tailcfg.UserProfile` object.
  factory UserProfile.fromJson(Map<String, Object?> json) => UserProfile(
    id: asInt(json['ID']) ?? 0,
    loginName: asString(json['LoginName']) ?? '',
    displayName: asString(json['DisplayName']) ?? '',
    profilePicUrl: asString(json['ProfilePicURL']),
  );

  /// Numeric user ID.
  final int id;

  /// Login name, e.g. `alice@example.com` or `tagged-devices`.
  final String loginName;

  /// Display name.
  final String displayName;

  /// Avatar URL, if any.
  final String? profilePicUrl;

  /// Whether this is the synthetic owner of tagged devices.
  bool get isTaggedDevices => loginName == 'tagged-devices';

  @override
  String toString() => 'UserProfile($id, $loginName)';
}

/// Status of one node (this node or a peer), `ipnstate.PeerStatus`.
final class PeerStatus {
  /// Creates a peer status.
  const PeerStatus({
    required this.id,
    required this.publicKey,
    required this.hostName,
    required this.dnsName,
    required this.os,
    required this.userId,
    required this.tailscaleIps,
    this.allowedIps = const [],
    this.tags = const [],
    this.online = false,
    this.active = false,
    this.expired = false,
    this.exitNode = false,
    this.exitNodeOption = false,
    this.relay = '',
    this.curAddr = '',
    this.rxBytes = 0,
    this.txBytes = 0,
    this.lastSeen,
    this.lastHandshake,
    this.keyExpiry,
    this.raw = const {},
  });

  /// Parses an `ipnstate.PeerStatus` object.
  factory PeerStatus.fromJson(Map<String, Object?> json) => PeerStatus(
    id: asString(json['ID']) ?? '',
    publicKey: asString(json['PublicKey']) ?? '',
    hostName: asString(json['HostName']) ?? '',
    dnsName: asString(json['DNSName']) ?? '',
    os: asString(json['OS']) ?? '',
    userId: asInt(json['UserID']) ?? 0,
    tailscaleIps: asStringList(json['TailscaleIPs']) ?? const [],
    allowedIps: asStringList(json['AllowedIPs']) ?? const [],
    tags: asStringList(json['Tags']) ?? const [],
    online: asBool(json['Online']) ?? false,
    active: asBool(json['Active']) ?? false,
    expired: asBool(json['Expired']) ?? false,
    exitNode: asBool(json['ExitNode']) ?? false,
    exitNodeOption: asBool(json['ExitNodeOption']) ?? false,
    relay: asString(json['Relay']) ?? '',
    curAddr: asString(json['CurAddr']) ?? '',
    rxBytes: asInt(json['RxBytes']) ?? 0,
    txBytes: asInt(json['TxBytes']) ?? 0,
    lastSeen: asTime(json['LastSeen']),
    lastHandshake: asTime(json['LastHandshake']),
    keyExpiry: asTime(json['KeyExpiry']),
    raw: json,
  );

  /// Stable node ID.
  final String id;

  /// Node public key (`nodekey:…`).
  final String publicKey;

  /// Hostname reported by the device (not unique).
  final String hostName;

  /// MagicDNS name with trailing dot, e.g. `demo-a.tail1234.ts.net.`.
  final String dnsName;

  /// Operating system reported by the device.
  final String os;

  /// Owner user ID (see [TailscaleStatus.users]).
  final int userId;

  /// Tailnet IPs (IPv4 and IPv6) as strings.
  final List<String> tailscaleIps;

  /// Routes the node may receive traffic for (CIDR strings).
  final List<String> allowedIps;

  /// ACL tags, e.g. `tag:server`.
  final List<String> tags;

  /// Whether the node is connected to the control plane.
  final bool online;

  /// Whether there is recent traffic with the node.
  final bool active;

  /// Whether the node key has expired.
  final bool expired;

  /// Whether this node is the selected exit node.
  final bool exitNode;

  /// Whether this node offers to be an exit node.
  final bool exitNodeOption;

  /// DERP relay region code in use, if any.
  final String relay;

  /// Direct endpoint in use, if any.
  final String curAddr;

  /// Bytes received from the peer.
  final int rxBytes;

  /// Bytes sent to the peer.
  final int txBytes;

  /// Last time control saw the node; `null` when online or unknown.
  final DateTime? lastSeen;

  /// Last WireGuard handshake; `null` if never.
  final DateTime? lastHandshake;

  /// Node key expiry; `null` if the key does not expire or is unknown.
  final DateTime? keyExpiry;

  /// The full decoded JSON object.
  final Map<String, Object?> raw;

  /// MagicDNS name without the trailing dot.
  String get magicDnsName => dnsName.endsWith('.')
      ? dnsName.substring(0, dnsName.length - 1)
      : dnsName;

  /// Short host label (the first DNS label), falling back to [hostName].
  String get name {
    final n = magicDnsName;
    if (n.isEmpty) return hostName;
    final dot = n.indexOf('.');
    return dot < 0 ? n : n.substring(0, dot);
  }

  /// The first IPv4 address, if any.
  String? get ipv4 => tailscaleIps.where((ip) => !ip.contains(':')).firstOrNull;

  /// The first IPv6 address, if any.
  String? get ipv6 => tailscaleIps.where((ip) => ip.contains(':')).firstOrNull;

  @override
  String toString() => 'PeerStatus($name, $tailscaleIps, online: $online)';
}

/// Information about the tailnet the node is connected to.
final class TailnetStatus {
  /// Creates a tailnet status.
  const TailnetStatus({
    required this.name,
    required this.magicDnsSuffix,
    required this.magicDnsEnabled,
  });

  /// Parses an `ipnstate.TailnetStatus` object.
  factory TailnetStatus.fromJson(Map<String, Object?> json) => TailnetStatus(
    name: asString(json['Name']) ?? '',
    magicDnsSuffix: asString(json['MagicDNSSuffix']) ?? '',
    magicDnsEnabled: asBool(json['MagicDNSEnabled']) ?? false,
  );

  /// Tailnet name, e.g. `example.com` or a Headscale base domain.
  final String name;

  /// MagicDNS suffix without surrounding dots, e.g. `tail1234.ts.net`.
  final String magicDnsSuffix;

  /// Whether MagicDNS is enabled on the tailnet.
  final bool magicDnsEnabled;

  @override
  String toString() => 'TailnetStatus($name, $magicDnsSuffix)';
}

/// The node status (`ipnstate.Status`), as returned by `tailscale_status_json`
/// and `/localapi/v0/status`.
final class TailscaleStatus {
  /// Creates a status.
  const TailscaleStatus({
    required this.version,
    required this.backendStateName,
    required this.authUrl,
    required this.tailscaleIps,
    this.self,
    this.health = const [],
    this.currentTailnet,
    this.certDomains = const [],
    this.peers = const [],
    this.users = const {},
    this.tun = false,
    this.raw = const {},
  });

  /// Parses an `ipnstate.Status` object.
  factory TailscaleStatus.fromJson(Map<String, Object?> json) {
    final self = asMap(json['Self']);
    final peerMap = asMap(json['Peer']);
    final userMap = asMap(json['User']);
    final tailnet = asMap(json['CurrentTailnet']);
    return TailscaleStatus(
      version: asString(json['Version']) ?? '',
      backendStateName: asString(json['BackendState']) ?? '',
      authUrl: asString(json['AuthURL']) ?? '',
      tailscaleIps: asStringList(json['TailscaleIPs']) ?? const [],
      self: self == null ? null : PeerStatus.fromJson(self),
      health: asStringList(json['Health']) ?? const [],
      currentTailnet: tailnet == null ? null : TailnetStatus.fromJson(tailnet),
      certDomains: asStringList(json['CertDomains']) ?? const [],
      peers: [
        if (peerMap != null)
          for (final v in peerMap.values)
            if (asMap(v) case final p?) PeerStatus.fromJson(p),
      ],
      users: {
        if (userMap != null)
          for (final e in userMap.entries)
            if (asMap(e.value) case final u?)
              (int.tryParse(e.key) ?? asInt(u['ID']) ?? 0):
                  UserProfile.fromJson(u),
      },
      tun: asBool(json['TUN']) ?? false,
      raw: json,
    );
  }

  /// Backend version string.
  final String version;

  /// Raw `BackendState` string (see [backendState] for the parsed value).
  final String backendStateName;

  /// Login URL if the node is waiting for interactive authentication.
  final String authUrl;

  /// This node's tailnet IPs.
  final List<String> tailscaleIps;

  /// This node's own status.
  final PeerStatus? self;

  /// Health problems (empty means healthy).
  final List<String> health;

  /// Current tailnet, `null` when not connected.
  final TailnetStatus? currentTailnet;

  /// DNS names the control plane will issue TLS certificates for.
  ///
  /// Empty on Headscale, which does not support `cert`/Funnel.
  final List<String> certDomains;

  /// Known peers.
  final List<PeerStatus> peers;

  /// User profiles keyed by user ID.
  final Map<int, UserProfile> users;

  /// Whether a kernel TUN device is used (always false for libtailscale).
  final bool tun;

  /// The full decoded JSON object.
  final Map<String, Object?> raw;

  /// Parsed backend state, `null` for unknown strings.
  BackendState? get backendState => BackendState.fromWireName(backendStateName);

  /// Whether the node is `Running`.
  bool get isRunning => backendState == BackendState.running;

  /// MagicDNS suffix from [currentTailnet], falling back to the legacy field.
  String get magicDnsSuffix =>
      currentTailnet?.magicDnsSuffix ?? asString(raw['MagicDNSSuffix']) ?? '';

  /// Whether the control plane can issue TLS certificates for this node.
  bool get supportsCertificates => certDomains.isNotEmpty;

  /// Looks up the owner of [peer].
  UserProfile? userOf(PeerStatus peer) => users[peer.userId];

  /// Finds a peer by tailnet IP.
  PeerStatus? peerByIp(String ip) =>
      peers.where((p) => p.tailscaleIps.contains(ip)).firstOrNull;

  @override
  String toString() =>
      'TailscaleStatus($backendStateName, ips: $tailscaleIps, '
      'peers: ${peers.length})';
}

/// The identity behind a tailnet IP (`/localapi/v0/whois`).
final class WhoIsResponse {
  /// Creates a response.
  const WhoIsResponse({
    required this.node,
    this.userProfile,
    this.capMap = const {},
    this.raw = const {},
  });

  /// Parses an `apitype.WhoIsResponse` object.
  factory WhoIsResponse.fromJson(Map<String, Object?> json) {
    final user = asMap(json['UserProfile']);
    return WhoIsResponse(
      node: WhoIsNode.fromJson(asMap(json['Node']) ?? const {}),
      userProfile: user == null ? null : UserProfile.fromJson(user),
      capMap: asMap(json['CapMap']) ?? const {},
      raw: json,
    );
  }

  /// The node that owns the address.
  final WhoIsNode node;

  /// The user that owns the node (synthetic for tagged nodes).
  final UserProfile? userProfile;

  /// Peer capabilities granted to us by that node (`tailcfg.PeerCapMap`).
  final Map<String, Object?> capMap;

  /// The full decoded JSON object.
  final Map<String, Object?> raw;

  @override
  String toString() => 'WhoIsResponse(${node.name}, ${userProfile?.loginName})';
}

/// The subset of `tailcfg.Node` that `whois` callers need.
final class WhoIsNode {
  /// Creates a node description.
  const WhoIsNode({
    required this.id,
    required this.stableId,
    required this.name,
    required this.addresses,
    this.tags = const [],
    this.hostname = '',
    this.os = '',
    this.userId = 0,
    this.online,
    this.raw = const {},
  });

  /// Parses a `tailcfg.Node` object.
  factory WhoIsNode.fromJson(Map<String, Object?> json) {
    final hostinfo = asMap(json['Hostinfo']) ?? const {};
    return WhoIsNode(
      id: asInt(json['ID']) ?? 0,
      stableId: asString(json['StableID']) ?? '',
      name: asString(json['Name']) ?? '',
      addresses: asStringList(json['Addresses']) ?? const [],
      tags: asStringList(json['Tags']) ?? const [],
      hostname: asString(hostinfo['Hostname']) ?? '',
      os: asString(hostinfo['OS']) ?? '',
      userId: asInt(json['User']) ?? 0,
      online: asBool(json['Online']),
      raw: json,
    );
  }

  /// Numeric node ID.
  final int id;

  /// Stable node ID.
  final String stableId;

  /// MagicDNS FQDN with trailing dot.
  final String name;

  /// Tailnet addresses as CIDR strings (`100.64.0.1/32`).
  final List<String> addresses;

  /// ACL tags.
  final List<String> tags;

  /// Hostname reported by the device.
  final String hostname;

  /// Operating system reported by the device.
  final String os;

  /// Owner user ID.
  final int userId;

  /// Whether the node is online, when reported.
  final bool? online;

  /// The full decoded JSON object.
  final Map<String, Object?> raw;

  /// The first DNS label of [name].
  String get shortName {
    final n = name.endsWith('.') ? name.substring(0, name.length - 1) : name;
    final dot = n.indexOf('.');
    return dot < 0 ? n : n.substring(0, dot);
  }
}
