import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'lan_platform_channel.dart';
import 'lan_protocol.dart';

const int discoveryPort = 9001;
const String discoveryMulticastAddress = '239.255.77.77';

class DiscoveryPacket {
  final String deviceId;
  final String deviceName;
  final String deviceType;
  final String appVersion;
  final String protocolVersion;
  final int tcpPort;
  final DateTime timestamp;
  final String transportIp;

  const DiscoveryPacket({
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    required this.appVersion,
    required this.protocolVersion,
    required this.tcpPort,
    required this.timestamp,
    required this.transportIp,
  });

  String get id => deviceId;
  String get name => deviceName;
  String get ip => transportIp;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'deviceType': deviceType,
        'appVersion': appVersion,
        'protocolVersion': protocolVersion,
        'tcpPort': tcpPort,
        'timestamp': timestamp.toIso8601String(),
      };

  factory DiscoveryPacket.fromJson(Map<String, dynamic> json) {
    return DiscoveryPacket(
      deviceId: (json['deviceId'] ?? json['id'] ?? '').toString(),
      deviceName: (json['deviceName'] ?? json['name'] ?? '').toString(),
      deviceType: (json['deviceType'] ?? 'unknown').toString(),
      appVersion: (json['appVersion'] ?? '').toString(),
      protocolVersion: (json['protocolVersion'] ?? '').toString(),
      tcpPort: int.tryParse((json['tcpPort'] ?? '').toString()) ?? 9002,
      timestamp: DateTime.tryParse((json['timestamp'] ?? '').toString()) ??
          DateTime.now(),
      transportIp: (json['ip'] ?? '').toString(),
    );
  }
}

class DiscoveryInterface {
  final String name;
  final NetworkInterface networkInterface;
  final InternetAddress address;
  final InternetAddress broadcast;

  const DiscoveryInterface({
    required this.name,
    required this.networkInterface,
    required this.address,
    required this.broadcast,
  });
}

class DiscoveryDiagnostics {
  final String myIp;
  final List<DiscoveryInterface> interfaces;
  final int broadcastsSent;
  final int inboundPackets;
  final DateTime startedAt;
  final DateTime? lastInboundPacketAt;
  final bool isListening;
  final bool multicastJoined;
  final bool multicastLockHeld;
  final String? lastPeerName;
  final String? lastPeerIp;

  const DiscoveryDiagnostics({
    required this.myIp,
    required this.interfaces,
    required this.broadcastsSent,
    required this.inboundPackets,
    required this.startedAt,
    required this.lastInboundPacketAt,
    required this.isListening,
    required this.multicastJoined,
    required this.multicastLockHeld,
    this.lastPeerName,
    this.lastPeerIp,
  });

  String get primaryInterfaceName =>
      interfaces.isEmpty ? 'unknown' : interfaces.first.name;
}

bool _isPrivateIpv4(String ip) {
  return ip.startsWith('10.') ||
      ip.startsWith('192.168.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(ip);
}

bool _isViableInterface(String name) {
  final lower = name.toLowerCase();

  if (lower == 'lo' || lower == 'lo0' || lower.startsWith('loopback')) {
    return false;
  }

  const blockedTokens = [
    'docker',
    'veth',
    'virbr',
    'tun',
    'tap',
    'tailscale',
    'utun',
    'awdl',
    'llw',
    'ham',
    'zt',
    'wg',
  ];

  for (final token in blockedTokens) {
    if (lower == token || lower.startsWith(token)) {
      return false;
    }
  }

  return true;
}

String _resolveDiscoveryPeerIp({
  required String senderIp,
  required String announcedIp,
}) {
  if (senderIp.isNotEmpty && senderIp != '0.0.0.0') {
    return senderIp;
  }
  if (announcedIp.isNotEmpty && announcedIp != '0.0.0.0') {
    return announcedIp;
  }
  return senderIp;
}

int _interfacePriority(String name, String ip) {
  final lower = name.toLowerCase();
  var score = 0;

  if (_isPrivateIpv4(ip)) score += 100;
  if (lower.startsWith('wl') ||
      lower.contains('wlan') ||
      lower.contains('wifi')) {
    score += 30;
  }
  if (lower.startsWith('en') ||
      lower.startsWith('eth') ||
      lower.startsWith('usb')) {
    score += 20;
  }
  if (lower.contains('ap') || lower.contains('hotspot')) {
    score += 10;
  }

  return score;
}

InternetAddress _classCBroadcast(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) {
    return InternetAddress('255.255.255.255');
  }

  return InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255');
}

Future<List<DiscoveryInterface>> getDiscoveryInterfaces() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  );

  final ranked = <({int score, DiscoveryInterface entry})>[];

  for (final interface in interfaces) {
    if (!_isViableInterface(interface.name)) continue;

    for (final addr in interface.addresses) {
      final ip = addr.address;
      if (ip.startsWith('127.')) continue;

      ranked.add((
        score: _interfacePriority(interface.name, ip),
        entry: DiscoveryInterface(
          name: interface.name,
          networkInterface: interface,
          address: addr,
          broadcast: _classCBroadcast(ip),
        ),
      ));
    }
  }

  ranked.sort((a, b) => b.score.compareTo(a.score));

  return ranked.map((item) => item.entry).toList(growable: false);
}

class DiscoveryService {
  final String myId;
  String myName;
  final int tcpPort;
  final void Function(DiscoveryPacket packet) onDeviceFound;
  final void Function(DiscoveryDiagnostics diagnostics)? onDiagnosticsChanged;

  RawDatagramSocket? _txSocket;
  RawDatagramSocket? _rxSocket;
  Timer? _broadcastTimer;
  List<DiscoveryInterface> _interfaces = const [];
  String _myIP = '0.0.0.0';
  int _broadcastCount = 0;
  int _inboundPacketCount = 0;
  DateTime? _startedAt;
  DateTime? _lastInboundPacketAt;
  bool _isListening = false;
  bool _multicastJoined = false;
  bool _multicastLockHeld = false;
  String? _lastPeerName;
  String? _lastPeerIp;

  DiscoveryService({
    required this.myId,
    required this.myName,
    required this.tcpPort,
    required this.onDeviceFound,
    this.onDiagnosticsChanged,
  });

  void updateIdentity({required String name}) {
    myName = name;
    unawaited(_sendDiscovery());
  }

  Future<void> start() async {
    _startedAt = DateTime.now();
    _interfaces = await getDiscoveryInterfaces();
    if (_interfaces.isNotEmpty) {
      _myIP = _interfaces.first.address.address;
    }
    _emitDiagnostics();
    debugPrint('My IP is: $_myIP');
    for (final entry in _interfaces) {
      debugPrint(
        'Discovery interface ${entry.name}: '
        '${entry.address.address} -> ${entry.broadcast.address}',
      );
    }

    try {
      _rxSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
    } on SocketException catch (error) {
      throw Exception(
        'Could not open UDP port $discoveryPort for discovery. '
        'Another ShareViaLAN instance may still be running, or the OS may be '
        'blocking inbound UDP traffic. Original error: $error',
      );
    }
    _rxSocket!.broadcastEnabled = true;
    await _prepareMulticast();
    _isListening = true;
    _emitDiagnostics();
    debugPrint('Listening for discovery packets on UDP $discoveryPort');

    _txSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _txSocket!.broadcastEnabled = true;

    _rxSocket!.listen((event) {
      if (event == RawSocketEvent.read) {
        while (true) {
          final datagram = _rxSocket!.receive();
          if (datagram == null) break;

          try {
            final senderIp = datagram.address.address;
            _inboundPacketCount += 1;
            _lastInboundPacketAt = DateTime.now();
            debugPrint(
              'Received ${datagram.data.length} discovery bytes from $senderIp',
            );

            final decoded = jsonDecode(utf8.decode(datagram.data));
            if (decoded is! Map) continue;

            final packet = DiscoveryPacket.fromJson(
              Map<String, dynamic>.from(decoded),
            );

            if (packet.deviceId.isEmpty || packet.deviceName.isEmpty) {
              continue;
            }

            if (packet.deviceId == myId) continue;

            final resolvedIp = _resolveDiscoveryPeerIp(
              senderIp: senderIp,
              announcedIp: packet.transportIp,
            );
            if (packet.transportIp.isNotEmpty &&
                packet.transportIp != '0.0.0.0' &&
                packet.transportIp != resolvedIp) {
              debugPrint(
                'Discovery IP mismatch from ${packet.deviceId}: '
                'announced=${packet.transportIp} sender=$senderIp; using $resolvedIp',
              );
            }
            final resolvedPacket = DiscoveryPacket(
              deviceId: packet.deviceId,
              deviceName: packet.deviceName,
              deviceType: packet.deviceType,
              appVersion: packet.appVersion,
              protocolVersion: packet.protocolVersion,
              tcpPort: packet.tcpPort,
              timestamp: packet.timestamp,
              transportIp: resolvedIp,
            );

            debugPrint(
              'Found device: ${resolvedPacket.name} at ${resolvedPacket.ip} '
              '(tcp ${resolvedPacket.tcpPort} from $senderIp)',
            );
            _lastPeerName = resolvedPacket.name;
            _lastPeerIp = resolvedPacket.ip;
            _emitDiagnostics();
            onDeviceFound(resolvedPacket);
          } catch (e) {
            debugPrint('Ignoring invalid discovery packet: $e');
          }
        }
        return;
      }

      if (event == RawSocketEvent.closed ||
          event == RawSocketEvent.readClosed) {
        debugPrint('Discovery receive socket closed');
      }
    });

    await _sendDiscovery();

    _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _sendDiscovery();
    });
  }

  Future<void> refresh() async {
    if (_rxSocket == null || _txSocket == null) {
      await start();
      return;
    }

    _interfaces = await getDiscoveryInterfaces();
    if (_interfaces.isNotEmpty) {
      _myIP = _interfaces.first.address.address;
    } else {
      _myIP = '0.0.0.0';
    }
    _joinMulticastGroups();
    _emitDiagnostics();
    await _sendDiscovery();
  }

  Future<void> _sendDiscovery() async {
    await _sendPacket();
  }

  Future<void> _prepareMulticast() async {
    _multicastLockHeld = await LanPlatformChannel.acquireAndroidMulticastLock();
    _joinMulticastGroups();
  }

  void _joinMulticastGroups() {
    final socket = _rxSocket;
    if (socket == null) return;
    final group = InternetAddress(discoveryMulticastAddress);
    var joined = false;
    for (final entry in _interfaces) {
      try {
        socket.joinMulticast(group, entry.networkInterface);
        joined = true;
        debugPrint(
          'Joined discovery multicast $discoveryMulticastAddress on ${entry.name}',
        );
      } catch (error) {
        debugPrint('Could not join multicast on ${entry.name}: $error');
      }
    }
    if (!joined) {
      try {
        socket.joinMulticast(group);
        joined = true;
      } catch (error) {
        debugPrint('Could not join default multicast group: $error');
      }
    }
    _multicastJoined = joined;
  }

  Future<void> _sendPacket() async {
    Uint8List payloadForPacket() {
      final packet = DiscoveryPacket(
        deviceId: myId,
        deviceName: myName,
        deviceType: Platform.operatingSystem,
        appVersion: lanComAppVersion,
        protocolVersion: lanComProtocolVersion,
        tcpPort: tcpPort,
        timestamp: DateTime.now(),
        transportIp: '',
      );
      return Uint8List.fromList(utf8.encode(jsonEncode(packet.toJson())));
    }

    final data = payloadForPacket();

    final sent = <String>{};
    void sendTo(InternetAddress address) {
      final key = address.address;
      if (!sent.add(key)) return;
      _txSocket?.send(data, address, discoveryPort);
      debugPrint(
        'Broadcasting discovery announce to ${address.address}: '
        '{deviceId: $myId, deviceName: $myName, tcpPort: $tcpPort}',
      );
    }

    if (_interfaces.isEmpty) {
      sendTo(InternetAddress('255.255.255.255'));
      sendTo(InternetAddress(discoveryMulticastAddress));
    } else {
      for (final entry in _interfaces) {
        sendTo(entry.broadcast);
        sendTo(InternetAddress(discoveryMulticastAddress));
      }
      sendTo(InternetAddress('255.255.255.255'));
    }
    _broadcastCount += 1;
    _emitDiagnostics();
  }

  void stop() {
    _broadcastTimer?.cancel();
    _isListening = false;
    _emitDiagnostics();
    _txSocket?.close();
    _rxSocket?.close();
    unawaited(LanPlatformChannel.releaseAndroidMulticastLock());
    _multicastLockHeld = false;
    _multicastJoined = false;
  }

  void _emitDiagnostics() {
    final startedAt = _startedAt;
    if (startedAt == null || onDiagnosticsChanged == null) return;

    onDiagnosticsChanged!(
      DiscoveryDiagnostics(
        myIp: _myIP,
        interfaces: List<DiscoveryInterface>.unmodifiable(_interfaces),
        broadcastsSent: _broadcastCount,
        inboundPackets: _inboundPacketCount,
        startedAt: startedAt,
        lastInboundPacketAt: _lastInboundPacketAt,
        isListening: _isListening,
        multicastJoined: _multicastJoined,
        multicastLockHeld: _multicastLockHeld,
        lastPeerName: _lastPeerName,
        lastPeerIp: _lastPeerIp,
      ),
    );
  }
}
