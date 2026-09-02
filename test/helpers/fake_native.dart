// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';
import 'dart:typed_data';

import 'package:libtailscale/src/api/exceptions.dart';
import 'package:libtailscale/src/ffi/libc.dart';
import 'package:libtailscale/src/ffi/tailscale_api.dart';

import 'libc_io.dart';

/// An in-memory [NativeTailscale] that records calls and hands out
/// socketpair ends where libtailscale would hand out connection fds.
///
/// Listener fds are also socketpair ends: a test "queues" a connection by
/// writing the connection fd (little-endian int32) into [listenerPeer]; the
/// reactor's [fakeAccept] reads it back.
final class FakeNative implements NativeTailscale {
  FakeNative({required this.loopbackPort});

  int loopbackPort;
  String ips = 'invalid IP,invalid IP';
  String statusJsonText = File(
    'test/fixtures/status_tailscale.json',
  ).readAsStringSync();
  Object? startError;
  final calls = <String>[];
  final settings = <String, Object?>{};
  final closed = <int>{};
  int logFd = -2;
  int _nextHandle = 42 << 16;

  /// Peer ends of listener socketpairs, keyed by the listener fd we returned.
  final listenerPeers = <int, int>{};

  /// Peer ends of dialled socketpairs, keyed by the connection fd we returned.
  final dialPeers = <int, int>{};

  /// Addresses passed to [dial] / [listen].
  final dialed = <String>[];
  final listened = <String>[];

  void _record(String call) => calls.add(call);

  void _checkOpen(int sd) {
    if (closed.contains(sd)) throw const TailscaleClosedException();
  }

  @override
  int newServer() {
    _record('newServer');
    return ++_nextHandle;
  }

  @override
  void start(int sd) {
    _checkOpen(sd);
    _record('start');
    if (startError case final e?) throw e;
  }

  @override
  void up(int sd) => _record('up');

  @override
  void close(int sd) {
    _checkOpen(sd);
    _record('close');
    closed.add(sd);
  }

  @override
  void setDir(int sd, String dir) {
    _record('setDir');
    settings['dir'] = dir;
  }

  @override
  void setHostname(int sd, String hostname) {
    _record('setHostname');
    settings['hostname'] = hostname;
  }

  @override
  void setAuthKey(int sd, String authKey) {
    _record('setAuthKey');
    settings['authKey'] = authKey;
  }

  @override
  void setControlUrl(int sd, String controlUrl) {
    _record('setControlUrl');
    settings['controlUrl'] = controlUrl;
  }

  @override
  void setEphemeral(int sd, bool ephemeral) {
    _record('setEphemeral');
    settings['ephemeral'] = ephemeral;
  }

  @override
  void setLogFd(int sd, int fd) {
    _record('setLogFd');
    logFd = fd;
  }

  @override
  String getIps(int sd) {
    _checkOpen(sd);
    return ips;
  }

  @override
  int dial(int sd, String network, String address) {
    _checkOpen(sd);
    _record('dial');
    dialed.add(address);
    final (ours, theirs) = Libc.socketpair();
    dialPeers[ours] = theirs;
    return ours;
  }

  @override
  int listen(int sd, String network, String address) {
    _checkOpen(sd);
    _record('listen');
    listened.add(address);
    final (ours, theirs) = Libc.socketpair();
    listenerPeers[ours] = theirs;
    return ours;
  }

  @override
  int accept(int sd, int listener) =>
      throw UnimplementedError('use fakeAccept');

  @override
  String remoteAddress(int listener, int conn) => '';

  @override
  LoopbackInfo loopback(int sd) {
    _checkOpen(sd);
    _record('loopback');
    return LoopbackInfo(
      host: '127.0.0.1',
      port: loopbackPort,
      proxyCredential: 'p' * 32,
      localApiCredential: 'l' * 32,
    );
  }

  @override
  String statusJson(int sd) {
    _checkOpen(sd);
    _record('statusJson');
    return statusJsonText;
  }

  @override
  String errmsg(int sd) => '';

  @override
  void enableFunnelToLocalhostPlaintextHttp1(int sd, int localhostPort) =>
      _record('funnel');

  /// Queues a connection on [listenerFd]: creates a socketpair, hands one end
  /// to the fake accept path and returns the test's end.
  int queueConnection(int listenerFd) {
    final peer = listenerPeers[listenerFd]!;
    final (forNode, forTest) = Libc.socketpair();
    final bytes = ByteData(4)..setInt32(0, forNode, Endian.little);
    writeAllBlocking(peer, bytes.buffer.asUint8List());
    return forTest;
  }

  void dispose() {
    for (final fd in [...listenerPeers.values, ...dialPeers.values]) {
      Libc.close(fd);
    }
  }
}

/// [AcceptFunction] matching [FakeNative.queueConnection].
({int fd, String remoteAddress}) fakeAccept(int serverHandle, int listenerFd) {
  final bytes = readSomeBlocking(listenerFd, 4);
  if (bytes.length != 4) throw StateError('EBADF: listener gone');
  return (
    fd: ByteData.sublistView(bytes).getInt32(0, Endian.little),
    remoteAddress: '100.64.0.99',
  );
}

/// Writes all of [bytes] to a blocking fd.
void writeAllBlocking(int fd, List<int> bytes) {
  final buf = Uint8List.fromList(bytes);
  var off = 0;
  while (off < buf.length) {
    final n = libcWrite(fd, buf, off);
    if (n < 0) throw LibcException('write', Libc.errno);
    off += n;
  }
}

/// Reads up to [max] bytes from a blocking fd (empty means EOF).
Uint8List readSomeBlocking(int fd, [int max = 65536]) => libcRead(fd, max);
