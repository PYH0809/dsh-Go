import 'dart:async';
import 'dart:typed_data';

import '../channel/rpc_client.dart';
import '../channel/secure_channel.dart';
import '../util/bytes.dart';
import 'peer_connection.dart';
import 'rtc_chunking.dart';
import 'transport.dart';

const String transportUpgradeCapability = 'remote.transport.upgrade.v1';

int _tierRank(RemoteTransportMode? mode) => switch (mode) {
  RemoteTransportMode.lan => 3,
  RemoteTransportMode.p2p => 2,
  RemoteTransportMode.turn => 1,
  RemoteTransportMode.relay || null => 0,
};

/// A WebRTC DataChannel leg negotiated over an already-authenticated
/// [RemoteRpcClient] session.
class UpgradedWebRtcTransport extends SecureHandshakeTransport {
  UpgradedWebRtcTransport._({
    required this.info,
    required RemotePeerConnection peer,
    required RemoteTransportMode mode,
    this.roundTripTime,
    this.peerNetwork,
  }) : _peer = peer,
       _mode = mode;

  @override
  final RemoteConnectionInfo info;
  final RemotePeerConnection _peer;
  RemoteTransportMode _mode;
  Duration? roundTripTime;
  RemotePeerNetworkInfo? peerNetwork;
  final RtcChunkCodec _incoming = RtcChunkCodec();
  final RtcChunkCodec _outgoing = RtcChunkCodec();
  bool _closed = false;
  bool _notified = false;
  TransportDataHandler? _onData;
  TransportClosedHandler? _onClosed;
  final List<(int, Uint8List)> _backlog = [];
  RemoteTransportClosed? _pendingClose;

  @override
  RemoteTransportMode get mode => _mode;

  Future<void> inspectNetwork() async {
    if (_closed) return;
    try {
      final stats = await _peer.stats();
      final path = selectedPeerPath(stats);
      if (path != null) _mode = path;
      roundTripTime = selectedPeerRoundTripTime(stats);
      peerNetwork = selectedPeerNetworkInfo(stats);
    } on Object {
      // Stats inspection is best-effort.
    }
  }

  static const List<int> _seqMagic = [0x44, 0x53, 0x48, 0x55]; // 'DSHU'

  static (int, Uint8List) _unwrapSequenced(Uint8List data) {
    if (data.length < 12 ||
        data[0] != _seqMagic[0] ||
        data[1] != _seqMagic[1] ||
        data[2] != _seqMagic[2] ||
        data[3] != _seqMagic[3]) {
      throw const FormatException('Missing DSHU sequence header');
    }
    final view = ByteData.sublistView(data, 0, 12);
    final hi = view.getUint32(4);
    final lo = view.getUint32(8);
    final counter = (hi * 0x100000000) + lo;
    return (counter, Uint8List.sublistView(data, 12));
  }

  static Uint8List _wrapSequenced(int counter, Uint8List ciphertext) {
    final out = Uint8List(12 + ciphertext.length);
    out.setAll(0, _seqMagic);
    ByteData.sublistView(out, 0, 12)
      ..setUint32(4, (counter >> 32) & 0xffffffff)
      ..setUint32(8, counter & 0xffffffff);
    out.setRange(12, out.length, ciphertext);
    return out;
  }

  void _handleFrame(Uint8List frame) {
    if (_closed) return;
    try {
      final assembled = _incoming.decode(frame);
      if (assembled == null) return;
      final (counter, ciphertext) = _unwrapSequenced(assembled);
      final handler = _onData;
      if (handler == null) {
        _backlog.add((counter, ciphertext));
      } else {
        handler(ciphertext, counter);
      }
    } on Object catch (error) {
      _handleClose('RTC_PROTOCOL_ERROR', 'Invalid WebRTC chunk: $error');
    }
  }

  void _handleClose(String code, String reason) {
    if (_closed) return;
    _closed = true;
    unawaited(_peer.close().catchError((Object _) {}));
    final closed = RemoteTransportClosed(code, reason);
    final handler = _onClosed;
    if (handler != null && !_notified) {
      _notified = true;
      handler(closed);
    } else {
      _pendingClose = closed;
    }
  }

  @override
  void listen({
    required TransportDataHandler onData,
    required TransportHandshakeHandler onHandshake,
    required TransportClosedHandler onClosed,
  }) {
    _onData = onData;
    _onClosed = onClosed;
    final items = [..._backlog];
    _backlog.clear();
    for (final (counter, ciphertext) in items) {
      onData(ciphertext, counter);
    }
    final pending = _pendingClose;
    if (pending != null && !_notified) {
      _notified = true;
      onClosed(pending);
    }
  }

  @override
  Future<void> sendHandshake(int step, Uint8List data) =>
      Future.error(const RemoteTransportException('INVALID_MESSAGE', 'Upgraded WebRTC legs do not send handshakes.'));

  @override
  Future<void> send(Uint8List ciphertext, {required int counter}) async {
    if (_closed) throw const RemoteTransportException('RTC_CLOSED', 'Upgraded WebRTC channel is closed.');
    for (final chunk in _outgoing.encode(_wrapSequenced(counter, ciphertext))) {
      if (_closed) throw const RemoteTransportException('RTC_CLOSED', 'Upgraded WebRTC channel closed mid-send.');
      await _peer.send(chunk);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _peer.close().catchError((Object _) {});
  }
}

/// Continuously promotes a Relay-established session upward (Relay -> TURN ->
/// P2P -> LAN) in the background without interrupting active RPCs or streams.
class LiveTransportUpgrader {
  LiveTransportUpgrader({
    required this.info,
    required this.channel,
    required this.rpc,
    required this.connector,
    required this.fetchIceServers,
    required this.onUpgraded,
    this.negotiateTimeout = const Duration(seconds: 10),
  }) {
    _eventSub = rpc.events.listen(_onEvent);
    unawaited(rpc.done.then((_) => close()));
  }

  final RemoteConnectionInfo info;
  final SecureChannel channel;
  final RemoteRpcClient rpc;
  final RemotePeerConnector connector;
  final Future<List<RemoteIceServer>> Function(String connectionId) fetchIceServers;
  final void Function(UpgradedWebRtcTransport transport) onUpgraded;
  final Duration negotiateTimeout;

  StreamSubscription<RemoteEvent>? _eventSub;
  UpgradedWebRtcTransport? _currentRtc;
  Future<bool>? _running;
  String? _activeAttemptId;
  RemotePeerConnection? _activePeer;
  bool _answered = false;
  int _attemptSeq = 0;
  final List<JsonMap> _pendingRemoteIce = [];
  bool _closed = false;

  UpgradedWebRtcTransport? get currentTransport => _currentRtc;

  RemoteTransportMode get currentMode => _currentRtc?.mode ?? channel.mode;

  bool get atTopTier => currentMode == RemoteTransportMode.lan;

  /// Triggers a background climb attempt toward a higher tier (up to LAN).
  Future<bool> promote({bool preferLan = false}) {
    if (_closed || rpc.isClosed) return Future.value(false);
    if (atTopTier) return Future.value(false);
    if (!preferLan && _tierRank(currentMode) >= _tierRank(RemoteTransportMode.p2p)) {
      return Future.value(false);
    }
    return _running ??= _runAttempt(preferLan: preferLan).whenComplete(() => _running = null);
  }

  void _onEvent(RemoteEvent event) {
    if (_closed || event.event != 'remote.transport.upgrade.ice') return;
    final data = asMap(event.data);
    if (data == null || data['attemptId'] != _activeAttemptId) return;
    final candidate = asMap(data['candidate']);
    if (candidate == null) return;
    final peer = _activePeer;
    if (peer == null) return;
    if (_answered) {
      unawaited(peer.addIceCandidate(candidate).catchError((Object _) {}));
    } else {
      _pendingRemoteIce.add(candidate);
    }
  }

  Future<bool> _runAttempt({required bool preferLan}) async {
    final attemptId = 'upg-${++_attemptSeq}-${DateTime.now().microsecondsSinceEpoch}';
    _activeAttemptId = attemptId;
    _answered = false;
    _pendingRemoteIce.clear();

    List<RemoteIceServer> ice = const [];
    try {
      ice = await fetchIceServers(info.connectionId).timeout(const Duration(seconds: 4));
    } on Object {
      // LAN / host candidates can succeed even when TURN credentials fail.
    }
    if (_closed || rpc.isClosed) return false;

    final opened = Completer<void>();
    final localIceQueue = <JsonMap>[];
    var offerSent = false;
    UpgradedWebRtcTransport? holder;

    late final RemotePeerConnection peer;
    try {
      peer = await connector(
        ice,
        RemotePeerHandlers(
          onIceCandidate: (candidate) {
            if (_closed || _activeAttemptId != attemptId) return;
            if (!offerSent) {
              localIceQueue.add(candidate);
            } else {
              unawaited(
                rpc
                    .call('remote.transport.upgrade.ice', {'attemptId': attemptId, 'candidate': candidate}, timeout: const Duration(seconds: 5))
                    .then((_) {}, onError: (Object _) {}),
              );
            }
          },
          onOpen: () {
            if (!opened.isCompleted) opened.complete();
          },
          onMessage: (bytes) => holder?._handleFrame(bytes),
          onClosed: (reason) {
            if (!opened.isCompleted) {
              opened.completeError(RemoteTransportException('RTC_CLOSED', reason));
            } else {
              holder?._handleClose('CONNECTION_FAILED', reason);
            }
          },
        ),
      );
    } on Object {
      return false;
    }
    if (_closed || rpc.isClosed) {
      await peer.close().catchError((Object _) {});
      return false;
    }
    _activePeer = peer;

    try {
      final sdp = await peer.createOffer(remoteDataChannelLabel);
      final reply = asMap(
        await rpc.call('remote.transport.upgrade.offer', {'attemptId': attemptId, 'sdp': sdp}, timeout: const Duration(seconds: 8)),
      );
      final answerSdp = asString(reply?['sdp']);
      if (answerSdp == null || answerSdp.isEmpty) throw StateError('Missing upgrade answer SDP');
      offerSent = true;
      for (final c in localIceQueue) {
        unawaited(
          rpc
              .call('remote.transport.upgrade.ice', {'attemptId': attemptId, 'candidate': c}, timeout: const Duration(seconds: 5))
              .then((_) {}, onError: (Object _) {}),
        );
      }
      localIceQueue.clear();

      await peer.setAnswer(answerSdp);
      _answered = true;
      for (final c in _pendingRemoteIce) {
        unawaited(peer.addIceCandidate(c).catchError((Object _) {}));
      }
      _pendingRemoteIce.clear();

      await opened.future.timeout(negotiateTimeout);

      // Poll stats once a selected pair is visible (or briefly on a local route
      // so a trailing LAN host-pair wins over P2P/TURN).
      RemoteTransportMode? detectedPath;
      Duration? rtt;
      RemotePeerNetworkInfo? netInfo;
      for (var i = 0; i < 6 && !_closed; i++) {
        try {
          final stats = await peer.stats();
          detectedPath = selectedPeerPath(stats);
          rtt = selectedPeerRoundTripTime(stats);
          netInfo = selectedPeerNetworkInfo(stats);
        } on Object {
          // Native stats can briefly fail right after open.
        }
        if (detectedPath == RemoteTransportMode.lan) break;
        if (!preferLan && detectedPath != null) break;
        if (i < 5) await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // When already on P2P and probing for LAN, never invent a synthetic path
      // if getStats() could not verify one; on the initial climb from Relay,
      // an open DataChannel with unverified stats conservatively reports P2P.
      final candidateMode = detectedPath ?? (currentMode == RemoteTransportMode.relay ? RemoteTransportMode.p2p : null);
      if (candidateMode == null) {
        unawaited(rpc.call('remote.transport.upgrade.abort', {'attemptId': attemptId}, timeout: const Duration(seconds: 3)).then((_) {}, onError: (Object _) {}));
        await peer.close().catchError((Object _) {});
        return false;
      }
      if (_tierRank(candidateMode) <= _tierRank(currentMode)) {
        unawaited(rpc.call('remote.transport.upgrade.abort', {'attemptId': attemptId}, timeout: const Duration(seconds: 3)).then((_) {}, onError: (Object _) {}));
        await peer.close().catchError((Object _) {});
        return false;
      }

      final upgraded = holder = UpgradedWebRtcTransport._(
        info: info,
        peer: peer,
        mode: candidateMode,
        roundTripTime: rtt,
        peerNetwork: netInfo,
      );

      // Register inbound decryption BEFORE telling the Host to switch its outbound leg.
      channel.attachIncomingTransport(upgraded);
      final activation = asMap(
        await rpc.call(
          'remote.transport.upgrade.activate',
          {'attemptId': attemptId, 'transport': candidateMode.name},
          timeout: const Duration(seconds: 6),
        ),
      );
      if (activation?['activated'] != true) {
        await upgraded.close();
        return false;
      }
      await channel.switchOutboundTransport(upgraded, closePrevious: true);
      _currentRtc = upgraded;
      onUpgraded(upgraded);
      return true;
    } on Object {
      unawaited(rpc.call('remote.transport.upgrade.abort', {'attemptId': attemptId}, timeout: const Duration(seconds: 3)).then((_) {}, onError: (Object _) {}));
      await peer.close().catchError((Object _) {});
      return false;
    } finally {
      if (_activeAttemptId == attemptId) {
        _activeAttemptId = null;
        _activePeer = null;
        _pendingRemoteIce.clear();
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _eventSub?.cancel();
    _eventSub = null;
    final peer = _activePeer;
    _activePeer = null;
    if (peer != null) await peer.close().catchError((Object _) {});
    final rtc = _currentRtc;
    _currentRtc = null;
    if (rtc != null) await rtc.close();
  }
}
