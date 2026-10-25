import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'discovery.dart';
import 'lan_platform_channel.dart';
import 'messaging.dart';

enum PermissionReadiness {
  ready,
  missingPermission,
  blockedByFirewall,
  blockedByBatteryOptimization,
  blockedByNetworkProfile,
  requiresManualAction,
  unsupported,
}

enum FirewallReadiness {
  ok,
  blocked,
  unknown,
  unsupported,
}

class PermissionStatus {
  final PermissionReadiness state;
  final String title;
  final String message;
  final List<String> details;
  final List<String> manualActions;

  const PermissionStatus({
    required this.state,
    required this.title,
    required this.message,
    this.details = const [],
    this.manualActions = const [],
  });

  bool get isReady => state == PermissionReadiness.ready;
}

class NetworkEnvironmentStatus {
  final FirewallReadiness firewall;
  final String networkProfile;
  final List<DiscoveryInterface> interfaces;
  final String message;
  final List<String> firewallCommands;

  const NetworkEnvironmentStatus({
    required this.firewall,
    required this.networkProfile,
    required this.interfaces,
    required this.message,
    this.firewallCommands = const [],
  });
}

class FirewallFixResult {
  final bool attempted;
  final bool success;
  final String message;
  final List<String> manualCommands;

  const FirewallFixResult({
    required this.attempted,
    required this.success,
    required this.message,
    this.manualCommands = const [],
  });
}

class ConnectionTestResult {
  final bool udpLoopbackOk;
  final bool tcpLoopbackOk;
  final bool tcpLanAddressOk;
  final List<String> discoveredPeers;
  final String? lastError;

  const ConnectionTestResult({
    required this.udpLoopbackOk,
    required this.tcpLoopbackOk,
    required this.tcpLanAddressOk,
    required this.discoveredPeers,
    this.lastError,
  });

  bool get isHealthy => udpLoopbackOk && tcpLoopbackOk;
}

abstract class PermissionManager {
  PermissionManager();

  factory PermissionManager.forPlatform() {
    if (kIsWeb) return UnsupportedPermissionManager();
    if (Platform.isAndroid) return AndroidPermissionManager();
    if (Platform.isWindows) return WindowsPermissionManager();
    if (Platform.isLinux) return LinuxPermissionManager();
    return UnsupportedPermissionManager();
  }

  Future<PermissionStatus> checkLanPermissions();
  Future<PermissionStatus> requestLanPermissions();
  Future<PermissionStatus> checkDiscoveryPermissions();
  Future<PermissionStatus> requestDiscoveryPermissions();
  Future<PermissionStatus> checkBackgroundConnectionPermissions();
  Future<PermissionStatus> requestBackgroundConnectionPermissions();
  Future<PermissionStatus> checkFileSharingPermissions();
  Future<PermissionStatus> requestFileSharingPermissions() =>
      checkFileSharingPermissions();

  Future<NetworkEnvironmentStatus> inspectNetworkEnvironment();
  Future<FirewallFixResult> fixFirewall();
  Future<ConnectionTestResult> runConnectionTest({
    required Iterable<PeerSummary> peers,
  });
  Future<void> openAppSettings();
  Future<void> openBatteryOptimizationSettings();
}

class AndroidPermissionManager extends PermissionManager {
  @override
  Future<PermissionStatus> checkLanPermissions() async {
    final sdk = await LanPlatformChannel.androidSdkInt();
    if (sdk >= 37 &&
        !await LanPlatformChannel.checkAndroidLocalNetworkPermission()) {
      return const PermissionStatus(
        state: PermissionReadiness.missingPermission,
        title: 'Local network permission missing',
        message:
            'LAN access is required to discover and communicate with nearby ShareViaLAN devices.',
        details: [
          'Android 17 blocks local sockets unless ACCESS_LOCAL_NETWORK is granted.',
        ],
      );
    }

    return PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'LAN sockets ready',
      message: sdk >= 36
          ? 'Android local-network checks are prepared for this runtime.'
          : 'Internet and network-state permissions are manifest permissions.',
      details: [
        if (sdk >= 36)
          'Android 16 opt-in local-network restrictions use Nearby Wi-Fi Devices.',
      ],
    );
  }

  @override
  Future<PermissionStatus> requestLanPermissions() async {
    final sdk = await LanPlatformChannel.androidSdkInt();
    if (sdk >= 37) {
      final granted =
          await LanPlatformChannel.requestAndroidLocalNetworkPermission();
      if (!granted) {
        return const PermissionStatus(
          state: PermissionReadiness.missingPermission,
          title: 'Local network permission denied',
          message:
              'LAN access is required to discover and communicate with nearby ShareViaLAN devices.',
        );
      }
    }
    return checkLanPermissions();
  }

  @override
  Future<PermissionStatus> checkDiscoveryPermissions() async {
    final sdk = await LanPlatformChannel.androidSdkInt();
    if (sdk >= 33) {
      final nearby = await ph.Permission.nearbyWifiDevices.status;
      if (!nearby.isGranted) {
        return const PermissionStatus(
          state: PermissionReadiness.requiresManualAction,
          title: 'Android nearby Wi-Fi permission not granted',
          message:
              'Direct LAN sockets can still work, but Wi-Fi discovery APIs (hotspot/P2P/local-network flows) may be limited until Nearby Wi-Fi is granted.',
          details: [
            'Location is not requested for socket-only LAN discovery on Android 13+.',
          ],
        );
      }
    }
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'Discovery permission ready',
      message: 'UDP broadcast, UDP multicast, and TCP discovery can start.',
    );
  }

  @override
  Future<PermissionStatus> requestDiscoveryPermissions() async {
    final sdk = await LanPlatformChannel.androidSdkInt();
    if (sdk >= 33) {
      final status = await ph.Permission.nearbyWifiDevices.request();
      if (!status.isGranted) {
        return const PermissionStatus(
          state: PermissionReadiness.requiresManualAction,
          title: 'Android nearby Wi-Fi permission not granted',
          message:
              'ShareViaLAN can continue with direct LAN sockets, but hotspot/P2P/local-network discovery may be reduced until Nearby Wi-Fi is granted.',
        );
      }
    }
    return checkDiscoveryPermissions();
  }

  @override
  Future<PermissionStatus> checkBackgroundConnectionPermissions() async {
    final sdk = await LanPlatformChannel.androidSdkInt();
    if (sdk >= 33) {
      final notification = await ph.Permission.notification.status;
      if (!notification.isGranted) {
        return const PermissionStatus(
          state: PermissionReadiness.missingPermission,
          title: 'Notification permission missing',
          message:
              'Android needs notification permission before ShareViaLAN can show foreground connection or transfer status.',
        );
      }
    }

    final ignoringBattery =
        await LanPlatformChannel.isIgnoringAndroidBatteryOptimizations();
    if (!ignoringBattery) {
      return const PermissionStatus(
        state: PermissionReadiness.blockedByBatteryOptimization,
        title: 'Battery optimization may pause LAN connections',
        message:
            'Battery optimization can stop continuous LAN discovery and direct connections while ShareViaLAN is backgrounded.',
        details: [
          'This is optional. ShareViaLAN will not force the exemption.',
        ],
      );
    }

    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'Background connections ready',
      message: 'Foreground service and notification readiness look good.',
    );
  }

  @override
  Future<PermissionStatus> requestBackgroundConnectionPermissions() async {
    final sdk = await LanPlatformChannel.androidSdkInt();
    if (sdk >= 33) {
      await ph.Permission.notification.request();
    }
    return checkBackgroundConnectionPermissions();
  }

  @override
  Future<PermissionStatus> checkFileSharingPermissions() async {
    final sdk = await LanPlatformChannel.androidSdkInt();
    if (sdk >= 23 && sdk <= 28 && !await ph.Permission.storage.isGranted) {
      return const PermissionStatus(
        state: PermissionReadiness.missingPermission,
        title: 'Downloads storage permission missing',
        message: 'Android 6–9 needs storage permission to save received files '
            'in Downloads/ShareViaLAN.',
        manualActions: [
          'Grant storage permission or enable it in app settings.'
        ],
      );
    }
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'File picker ready',
      message:
          'ShareViaLAN uses the system file picker and does not need broad storage access.',
    );
  }

  @override
  Future<PermissionStatus> requestFileSharingPermissions() async {
    final sdk = await LanPlatformChannel.androidSdkInt();
    if (sdk >= 23 && sdk <= 28) {
      await ph.Permission.storage.request();
    }
    return checkFileSharingPermissions();
  }

  @override
  Future<NetworkEnvironmentStatus> inspectNetworkEnvironment() async {
    final interfaces = await getDiscoveryInterfaces();
    final lockHeld = await LanPlatformChannel.isAndroidMulticastLockHeld();
    return NetworkEnvironmentStatus(
      firewall: FirewallReadiness.unsupported,
      networkProfile: 'Android',
      interfaces: interfaces,
      message: lockHeld
          ? 'Android multicast lock is currently held for discovery.'
          : 'Android firewall is app-managed by permissions; multicast lock is acquired only while discovery runs.',
    );
  }

  @override
  Future<FirewallFixResult> fixFirewall() async {
    return const FirewallFixResult(
      attempted: false,
      success: false,
      message: 'Android does not expose a ShareViaLAN firewall rule to fix.',
    );
  }

  @override
  Future<ConnectionTestResult> runConnectionTest({
    required Iterable<PeerSummary> peers,
  }) {
    return _runSocketSelfTest(peers: peers);
  }

  @override
  Future<void> openAppSettings() => LanPlatformChannel.openAndroidAppSettings();

  @override
  Future<void> openBatteryOptimizationSettings() =>
      LanPlatformChannel.openAndroidBatteryOptimizationSettings();
}

class WindowsPermissionManager extends PermissionManager {
  static const _tcpRuleName = 'ShareViaLAN TCP $messagingPort';
  static const _udpRuleName = 'ShareViaLAN UDP $discoveryPort';

  @override
  Future<PermissionStatus> checkLanPermissions() async {
    final environment = await inspectNetworkEnvironment();
    if (environment.networkProfile.toLowerCase().contains('public')) {
      return const PermissionStatus(
        state: PermissionReadiness.blockedByNetworkProfile,
        title: 'Public network profile',
        message:
            'Device is on a public network profile; inbound traffic may be blocked.',
      );
    }
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'Windows LAN sockets ready',
      message: 'Normal Win32 TCP and UDP sockets are available.',
    );
  }

  @override
  Future<PermissionStatus> requestLanPermissions() => checkLanPermissions();

  @override
  Future<PermissionStatus> checkDiscoveryPermissions() async {
    final environment = await inspectNetworkEnvironment();
    if (environment.firewall == FirewallReadiness.blocked) {
      return const PermissionStatus(
        state: PermissionReadiness.blockedByFirewall,
        title: 'Firewall is blocking incoming ShareViaLAN messages',
        message:
            'Windows Defender needs private-network inbound rules for UDP 9001 and TCP 9002.',
      );
    }
    if (environment.firewall == FirewallReadiness.unknown) {
      return const PermissionStatus(
        state: PermissionReadiness.requiresManualAction,
        title: 'Firewall status unknown',
        message:
            'ShareViaLAN could not verify Windows Defender firewall rules automatically.',
      );
    }
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'Windows discovery ready',
      message: 'Private-network firewall rules are present.',
    );
  }

  @override
  Future<PermissionStatus> requestDiscoveryPermissions() =>
      checkDiscoveryPermissions();

  @override
  Future<PermissionStatus> checkBackgroundConnectionPermissions() async {
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'Desktop listener ready',
      message:
          'Windows keeps ShareViaLAN listeners active while the app is running.',
    );
  }

  @override
  Future<PermissionStatus> requestBackgroundConnectionPermissions() =>
      checkBackgroundConnectionPermissions();

  @override
  Future<PermissionStatus> checkFileSharingPermissions() async {
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'File picker ready',
      message:
          'Windows file sharing uses selected paths and normal user access.',
    );
  }

  @override
  Future<NetworkEnvironmentStatus> inspectNetworkEnvironment() async {
    final interfaces = await getDiscoveryInterfaces();
    final profile = await _windowsNetworkProfile();
    final firewall = await _windowsFirewallStatus();
    return NetworkEnvironmentStatus(
      firewall: firewall,
      networkProfile: profile,
      interfaces: interfaces,
      message: switch (firewall) {
        FirewallReadiness.ok => 'Windows private firewall rules are present.',
        FirewallReadiness.blocked =>
          'Firewall is blocking incoming ShareViaLAN messages.',
        FirewallReadiness.unknown =>
          'Windows firewall status could not be verified.',
        FirewallReadiness.unsupported => 'Windows firewall check unsupported.',
      },
      firewallCommands: _windowsFirewallCommands(elevated: false),
    );
  }

  @override
  Future<FirewallFixResult> fixFirewall() async {
    final commands = _windowsFirewallCommands(elevated: false);
    var allOk = true;
    for (final command in commands) {
      final result = await _runShell(command);
      allOk = allOk && result?.exitCode == 0;
    }
    if (allOk) {
      return const FirewallFixResult(
        attempted: true,
        success: true,
        message: 'Windows firewall rules were added for Private networks.',
      );
    }

    final elevated = _windowsFirewallCommands(elevated: true);
    return FirewallFixResult(
      attempted: true,
      success: false,
      message:
          'Automatic firewall fix needs administrator approval. Run these commands in an elevated terminal.',
      manualCommands: elevated,
    );
  }

  @override
  Future<ConnectionTestResult> runConnectionTest({
    required Iterable<PeerSummary> peers,
  }) {
    return _runSocketSelfTest(peers: peers);
  }

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> openBatteryOptimizationSettings() async {}

  Future<String> _windowsNetworkProfile() async {
    final result = await _run(
      'powershell',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'Get-NetConnectionProfile | Select-Object -First 1 -ExpandProperty NetworkCategory',
      ],
    );
    final output = (result?.stdout ?? '').toString().trim();
    return output.isEmpty ? 'Unknown' : output;
  }

  Future<FirewallReadiness> _windowsFirewallStatus() async {
    final tcp = await _run('netsh', [
      'advfirewall',
      'firewall',
      'show',
      'rule',
      'name=$_tcpRuleName',
    ]);
    final udp = await _run('netsh', [
      'advfirewall',
      'firewall',
      'show',
      'rule',
      'name=$_udpRuleName',
    ]);
    if (tcp == null || udp == null) return FirewallReadiness.unknown;
    final tcpText = '${tcp.stdout}\n${tcp.stderr}'.toLowerCase();
    final udpText = '${udp.stdout}\n${udp.stderr}'.toLowerCase();
    if (tcp.exitCode == 0 &&
        udp.exitCode == 0 &&
        tcpText.contains('enabled') &&
        udpText.contains('enabled')) {
      return FirewallReadiness.ok;
    }
    if (tcpText.contains('no rules match') ||
        udpText.contains('no rules match')) {
      return FirewallReadiness.blocked;
    }
    return FirewallReadiness.unknown;
  }

  List<String> _windowsFirewallCommands({required bool elevated}) {
    final exe = Platform.resolvedExecutable;
    final tcp =
        'netsh advfirewall firewall add rule name="$_tcpRuleName" dir=in action=allow program="$exe" protocol=TCP localport=$messagingPort profile=private remoteip=localsubnet';
    final udp =
        'netsh advfirewall firewall add rule name="$_udpRuleName" dir=in action=allow program="$exe" protocol=UDP localport=$discoveryPort profile=private remoteip=localsubnet';
    if (!elevated) return [tcp, udp];
    return [
      'Start-Process netsh -Verb RunAs -Wait -ArgumentList \'${tcp.substring('netsh '.length)}\'',
      'Start-Process netsh -Verb RunAs -Wait -ArgumentList \'${udp.substring('netsh '.length)}\'',
    ];
  }
}

class LinuxPermissionManager extends PermissionManager {
  @override
  Future<PermissionStatus> checkLanPermissions() async {
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'Linux LAN sockets ready',
      message: 'TCP and UDP ports above 1024 do not require root.',
      details: [
        'ShareViaLAN does not require CAP_NET_RAW, CAP_NET_ADMIN, or root.',
      ],
    );
  }

  @override
  Future<PermissionStatus> requestLanPermissions() => checkLanPermissions();

  @override
  Future<PermissionStatus> checkDiscoveryPermissions() async {
    final environment = await inspectNetworkEnvironment();
    if (environment.firewall == FirewallReadiness.blocked) {
      return PermissionStatus(
        state: PermissionReadiness.blockedByFirewall,
        title: 'Firewall is blocking incoming ShareViaLAN messages',
        message: environment.message,
        manualActions: environment.firewallCommands,
      );
    }
    if (environment.firewall == FirewallReadiness.unknown) {
      return PermissionStatus(
        state: PermissionReadiness.requiresManualAction,
        title: 'Firewall status unknown',
        message: environment.message,
        manualActions: environment.firewallCommands,
      );
    }
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'Linux discovery ready',
      message: 'Firewall checks did not find a blocking rule.',
    );
  }

  @override
  Future<PermissionStatus> requestDiscoveryPermissions() =>
      checkDiscoveryPermissions();

  @override
  Future<PermissionStatus> checkBackgroundConnectionPermissions() async {
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'Desktop listener ready',
      message:
          'Linux keeps ShareViaLAN listeners active while the app is running.',
    );
  }

  @override
  Future<PermissionStatus> requestBackgroundConnectionPermissions() =>
      checkBackgroundConnectionPermissions();

  @override
  Future<PermissionStatus> checkFileSharingPermissions() async {
    return const PermissionStatus(
      state: PermissionReadiness.ready,
      title: 'File picker ready',
      message: 'Linux file sharing uses selected paths and normal user access.',
    );
  }

  @override
  Future<NetworkEnvironmentStatus> inspectNetworkEnvironment() async {
    final interfaces = await getDiscoveryInterfaces();
    final firewalld = await _firewalldStatus();
    if (firewalld != FirewallReadiness.unsupported) {
      return NetworkEnvironmentStatus(
        firewall: firewalld,
        networkProfile: 'Linux',
        interfaces: interfaces,
        message: firewalld == FirewallReadiness.ok
            ? 'firewalld has ShareViaLAN ports open in the active zone.'
            : 'firewalld may be blocking ShareViaLAN.',
        firewallCommands: _firewalldCommands,
      );
    }

    final ufw = await _ufwStatus();
    if (ufw != FirewallReadiness.unsupported) {
      return NetworkEnvironmentStatus(
        firewall: ufw,
        networkProfile: 'Linux',
        interfaces: interfaces,
        message: ufw == FirewallReadiness.ok
            ? 'ufw allows ShareViaLAN ports or is inactive.'
            : 'ufw may be blocking ShareViaLAN.',
        firewallCommands: _ufwCommands,
      );
    }

    return NetworkEnvironmentStatus(
      firewall: FirewallReadiness.unknown,
      networkProfile: 'Linux',
      interfaces: interfaces,
      message:
          'No supported firewall tool was detected. Check nftables or iptables if peers cannot connect.',
      firewallCommands: [
        'sudo nft list ruleset',
        'sudo iptables -S',
      ],
    );
  }

  @override
  Future<FirewallFixResult> fixFirewall() async {
    final environment = await inspectNetworkEnvironment();
    return FirewallFixResult(
      attempted: false,
      success: false,
      message:
          'ShareViaLAN will not disable or rewrite Linux firewall policy. Run the matching commands for your firewall.',
      manualCommands: environment.firewallCommands,
    );
  }

  @override
  Future<ConnectionTestResult> runConnectionTest({
    required Iterable<PeerSummary> peers,
  }) {
    return _runSocketSelfTest(peers: peers);
  }

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> openBatteryOptimizationSettings() async {}

  static const _firewalldCommands = [
    'sudo firewall-cmd --add-port=9001/udp --add-port=9002/tcp',
    'sudo firewall-cmd --runtime-to-permanent',
  ];

  static const _ufwCommands = [
    'sudo ufw allow 9001/udp',
    'sudo ufw allow 9002/tcp',
  ];

  Future<FirewallReadiness> _firewalldStatus() async {
    final state = await _run('firewall-cmd', ['--state']);
    if (state == null || state.exitCode != 0) {
      return FirewallReadiness.unsupported;
    }
    final udp = await _run('firewall-cmd', ['--query-port=9001/udp']);
    final tcp = await _run('firewall-cmd', ['--query-port=9002/tcp']);
    if (udp?.exitCode == 0 && tcp?.exitCode == 0) {
      return FirewallReadiness.ok;
    }
    return FirewallReadiness.blocked;
  }

  Future<FirewallReadiness> _ufwStatus() async {
    final result = await _run('ufw', ['status']);
    if (result == null) return FirewallReadiness.unsupported;
    final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
    if (output.contains('inactive')) return FirewallReadiness.ok;
    if (!output.contains('status: active')) return FirewallReadiness.unknown;
    final udpOk =
        output.contains('$discoveryPort/udp') && output.contains('allow');
    final tcpOk =
        output.contains('$messagingPort/tcp') && output.contains('allow');
    return udpOk && tcpOk ? FirewallReadiness.ok : FirewallReadiness.blocked;
  }
}

class UnsupportedPermissionManager extends PermissionManager {
  @override
  Future<PermissionStatus> checkLanPermissions() async => _unsupported;

  @override
  Future<PermissionStatus> requestLanPermissions() async => _unsupported;

  @override
  Future<PermissionStatus> checkDiscoveryPermissions() async => _unsupported;

  @override
  Future<PermissionStatus> requestDiscoveryPermissions() async => _unsupported;

  @override
  Future<PermissionStatus> checkBackgroundConnectionPermissions() async =>
      _unsupported;

  @override
  Future<PermissionStatus> requestBackgroundConnectionPermissions() async =>
      _unsupported;

  @override
  Future<PermissionStatus> checkFileSharingPermissions() async => _unsupported;

  @override
  Future<NetworkEnvironmentStatus> inspectNetworkEnvironment() async {
    return const NetworkEnvironmentStatus(
      firewall: FirewallReadiness.unsupported,
      networkProfile: 'Unsupported',
      interfaces: [],
      message: 'This platform is not supported by the LAN readiness checker.',
    );
  }

  @override
  Future<FirewallFixResult> fixFirewall() async {
    return const FirewallFixResult(
      attempted: false,
      success: false,
      message: 'Firewall fixing is not supported on this platform.',
    );
  }

  @override
  Future<ConnectionTestResult> runConnectionTest({
    required Iterable<PeerSummary> peers,
  }) {
    return _runSocketSelfTest(peers: peers);
  }

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> openBatteryOptimizationSettings() async {}

  static const _unsupported = PermissionStatus(
    state: PermissionReadiness.unsupported,
    title: 'Unsupported platform',
    message:
        'ShareViaLAN readiness checks support Android, Windows, and Linux.',
  );
}

Future<ConnectionTestResult> _runSocketSelfTest({
  required Iterable<PeerSummary> peers,
}) async {
  var udpOk = false;
  var tcpLoopbackOk = false;
  var tcpLanOk = false;
  String? lastError;

  try {
    final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final completer = Completer<bool>();
    late final StreamSubscription<RawSocketEvent> subscription;
    subscription = udp.listen((event) {
      if (event == RawSocketEvent.read && udp.receive() != null) {
        if (!completer.isCompleted) completer.complete(true);
      }
    });
    udp.send([1, 2, 3], InternetAddress.loopbackIPv4, udp.port);
    udpOk = await completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => false,
    );
    await subscription.cancel();
    udp.close();
  } catch (error) {
    lastError = 'UDP self-test failed: $error';
  }

  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      messagingPort,
      timeout: const Duration(seconds: 2),
    );
    tcpLoopbackOk = true;
    socket.destroy();
  } catch (error) {
    lastError = 'TCP listener is not reachable locally: $error';
  }

  try {
    final interfaces = await getDiscoveryInterfaces();
    if (interfaces.isNotEmpty) {
      final socket = await Socket.connect(
        interfaces.first.address,
        messagingPort,
        timeout: const Duration(seconds: 2),
      );
      tcpLanOk = true;
      socket.destroy();
    }
  } catch (error) {
    lastError =
        'TCP listener is not reachable on the active LAN address: $error';
  }

  return ConnectionTestResult(
    udpLoopbackOk: udpOk,
    tcpLoopbackOk: tcpLoopbackOk,
    tcpLanAddressOk: tcpLanOk,
    discoveredPeers: peers.map((peer) => peer.name).toList(growable: false),
    lastError: lastError,
  );
}

Future<ProcessResult?> _run(String executable, List<String> arguments) async {
  try {
    return await Process.run(executable, arguments).timeout(
      const Duration(seconds: 4),
    );
  } on Object catch (error) {
    debugPrint('Command failed: $executable ${arguments.join(' ')}: $error');
    return null;
  }
}

Future<ProcessResult?> _runShell(String command) async {
  if (Platform.isWindows) {
    return _run('cmd', ['/c', command]);
  }
  return _run('sh', ['-c', command]);
}
