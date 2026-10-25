import 'package:flutter_test/flutter_test.dart';
import 'package:lancom/discovery.dart';
import 'package:lancom/lan_protocol.dart';
import 'package:lancom/messaging.dart';

void main() {
  test('Discovery packet carries direct-mode metadata', () {
    final packet = DiscoveryPacket(
      deviceId: 'A',
      deviceName: 'Alice',
      deviceType: 'linux',
      appVersion: lanComAppVersion,
      protocolVersion: lanComProtocolVersion,
      tcpPort: messagingPort,
      timestamp: DateTime.utc(2026),
      transportIp: '192.168.1.10',
    );

    final json = packet.toJson();

    expect(json['deviceId'], 'A');
    expect(json['deviceName'], 'Alice');
    expect(json['deviceType'], 'linux');
    expect(json['appVersion'], lanComAppVersion);
    expect(json['protocolVersion'], lanComProtocolVersion);
    expect(json['tcpPort'], messagingPort);
    expect(json['timestamp'], '2026-01-01T00:00:00.000Z');
    expect(json.containsKey('ip'), isFalse);
  });

  test('Direct peer identity is stable when IP changes', () {
    final service = MessagingService(myId: 'A', myName: 'A');

    service.debugRegisterDirectPeer(
      peerId: 'B',
      peerName: 'B',
      peerIp: '192.168.43.20',
    );
    service.debugRegisterDirectPeer(
      peerId: 'B',
      peerName: 'B',
      peerIp: '192.168.43.44',
    );

    final peers =
        service.knownPeers.where((peer) => peer.peerId == 'B').toList();
    expect(peers.length, 1);
    expect(peers.single.ip, '192.168.43.44');
    expect(peers.single.isDirect, isTrue);
    expect(peers.single.hopCount, 1);
    expect(peers.single.nextHopId, 'B');
  });

  test('Peer becomes stale before offline', () {
    final service = MessagingService(myId: 'A', myName: 'A');

    service.debugRegisterDirectPeer(
      peerId: 'B',
      peerName: 'B',
      peerIp: '10.0.0.2',
      seenAt: DateTime.now().subtract(const Duration(seconds: 95)),
    );

    final peer = service.peerSummaryFor('B');
    expect(peer, isNotNull);
    expect(peer!.routeStatus, PeerRouteStatus.stale);
    expect(peer.isOnline, isFalse);
    expect(peer.isDirect, isTrue);
    expect(peer.isReachable, isTrue);
  });

  test('Permission does not hide a verified direct peer', () {
    final service = MessagingService(myId: 'A', myName: 'A');

    service.debugRegisterDirectPeer(
      peerId: 'B',
      peerName: 'B',
      peerIp: '10.0.0.2',
    );

    final peer = service.peerSummaryFor('B');
    expect(service.canMessage('B'), isFalse);
    expect(peer, isNotNull);
    expect(peer!.routeStatus, PeerRouteStatus.directOnline);
  });

  test('Only direct peers are summarized; unrelated peers are not invented',
      () {
    final service = MessagingService(myId: 'A', myName: 'A');

    service.debugRegisterDirectPeer(
      peerId: 'B',
      peerName: 'B',
      peerIp: '10.0.0.2',
    );

    expect(service.peerSummaryFor('B'), isNotNull);
    expect(service.peerSummaryFor('C'), isNull);
    expect(service.debugNextHopFor('B'), 'B');
    expect(service.debugHopCountFor('B'), 1);
    expect(service.debugNextHopFor('C'), isNull);
  });
}
