import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';
import 'support/fake_rtc.dart';

void main() {
  late FakeRemoteServer server;
  late FakeRemoteHost host;
  late FakeRtcNetwork rtc;
  late RemoteAccount account;

  setUp(() async {
    server = await FakeRemoteServer.start();
    server.webrtc = true;
    rtc = FakeRtcNetwork();
    host = await FakeRemoteHost.start(server);
    host.webrtc = true;
    host.rtcNetwork = rtc;
    host.capabilities.add('remote.transport.upgrade.v1');
    await host.goOffline();
    await host.goOnline();
    account = RemoteAccount(
      secrets: MemorySecretStore(),
      serverUrl: server.url,
      peerConnector: rtc.connector,
      relayFirstUpgrade: true,
    );
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
  });

  tearDown(() async {
    expect(server.protocolErrors, isEmpty);
    await account.close();
    await host.close();
    await server.close();
  });

  test('connects immediately over Relay, climbs to P2P, and climbs further to LAN without dropping live streams', () async {
    // Initially cellular: P2P pair only.
    rtc.stats = pairStats('srflx', '203.0.113.7', 'srflx', '198.51.100.9');
    final seenTransports = <String?>[];
    late FakeHostStream liveStream;
    host.onOpen = (s) {
      liveStream = s;
      s.push('from-relay');
    };

    final target = (await account.listHosts()).single;
    final client = await account.connectHost(
      target,
      onState: (s) {
        if (s.phase == RemoteConnectionPhase.connected) seenTransports.add(s.transport);
      },
    );

    final session = client.remoteCarrier!.session!;
    expect(session.transport, 'relay', reason: 'starts immediately on Relay with zero WebRTC wait');

    final items = <Object?>[];
    final sub = client.mux.open('session/follow', const {}).items.listen(items.add);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(items, ['from-relay']);

    // Background 400ms timer promotes Relay -> P2P seamlessly.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(session.transport, 'p2p');
    expect(seenTransports, containsAllInOrder(['relay', 'p2p']));
    liveStream.push('from-p2p');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(items, ['from-relay', 'from-p2p']);

    // User walks onto Wi-Fi / LAN: promote(preferLan: true) climbs P2P -> LAN!
    rtc.stats = pairStats('host', '192.168.1.20', 'host', '192.168.1.30');
    final promotedToLan = await session.promoteTransport!(preferLan: true);
    expect(promotedToLan, isTrue);
    expect(session.transport, 'lan');
    await Future<void>.delayed(Duration.zero);
    expect(seenTransports, containsAllInOrder(['relay', 'p2p', 'lan']));
    expect(rtc.clients.first.closed, isTrue, reason: 'superseded P2P leg is cleanly closed');
    expect(rtc.clients.last.closed, isFalse, reason: 'new LAN leg is active');

    // Same Noise session & same open stream continue over LAN without interruption!
    liveStream.push('from-lan');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(items, ['from-relay', 'from-p2p', 'from-lan']);
    expect(host.handshakes, hasLength(1), reason: 'zero reconnects or re-handshakes across Relay -> P2P -> LAN');

    await sub.cancel();
  });

  test('older Host without remote.transport.upgrade.v1 connects over Relay once and falls back to pre-handshake WebRTC on reconnect', () async {
    host.capabilities.remove('remote.transport.upgrade.v1');
    rtc.stats = pairStats('host', '192.168.1.20', 'host', '192.168.1.30');
    final target = (await account.listHosts()).single;
    final client = await account.connectHost(target);
    expect(client.remoteCarrier!.session!.transport, 'relay');

    client.remoteCarrier!.reconnect();
    await client.mux.ready();
    expect(client.remoteCarrier!.session!.transport, 'lan');
  });
}
