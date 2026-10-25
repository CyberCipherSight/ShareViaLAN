import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'discovery.dart';
import 'messaging.dart';
import 'permission_manager.dart';

Future<void> _waitForUiTransitionToSettle() async {
  await Future<void>.delayed(Duration.zero);
  await WidgetsBinding.instance.endOfFrame;
}

class ConnectionReadinessScreen extends StatefulWidget {
  final PermissionManager permissionManager;
  final DiscoveryDiagnostics? discoveryDiagnostics;
  final ConnectionDiagnostics connectionDiagnostics;
  final List<PeerSummary> peers;
  final Future<void> Function() onStartDiscovery;
  final Future<bool> Function(String endpoint) onManualConnect;

  const ConnectionReadinessScreen({
    super.key,
    required this.permissionManager,
    required this.discoveryDiagnostics,
    required this.connectionDiagnostics,
    required this.peers,
    required this.onStartDiscovery,
    required this.onManualConnect,
  });

  @override
  State<ConnectionReadinessScreen> createState() =>
      _ConnectionReadinessScreenState();
}

class _ConnectionReadinessScreenState extends State<ConnectionReadinessScreen> {
  PermissionStatus? _lan;
  PermissionStatus? _discovery;
  PermissionStatus? _background;
  PermissionStatus? _fileSharing;
  NetworkEnvironmentStatus? _environment;
  ConnectionTestResult? _testResult;
  bool _loading = true;
  bool _runningAction = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final lan = await widget.permissionManager.checkLanPermissions();
    final discovery =
        await widget.permissionManager.checkDiscoveryPermissions();
    final background =
        await widget.permissionManager.checkBackgroundConnectionPermissions();
    final fileSharing =
        await widget.permissionManager.checkFileSharingPermissions();
    final environment =
        await widget.permissionManager.inspectNetworkEnvironment();
    if (!mounted) return;
    setState(() {
      _lan = lan;
      _discovery = discovery;
      _background = background;
      _fileSharing = fileSharing;
      _environment = environment;
      _loading = false;
    });
  }

  Future<void> _grantRequiredPermissions() async {
    await _runAction(() async {
      await widget.permissionManager.requestLanPermissions();
      await widget.permissionManager.requestDiscoveryPermissions();
      await widget.permissionManager.requestBackgroundConnectionPermissions();
      await widget.permissionManager.requestFileSharingPermissions();
      await _reload();
    });
  }

  Future<void> _startDiscovery() async {
    await _runAction(() async {
      await widget.onStartDiscovery();
      await _reload();
    });
  }

  Future<void> _runConnectionTest() async {
    await _runAction(() async {
      final result = await widget.permissionManager.runConnectionTest(
        peers: widget.peers,
      );
      if (!mounted) return;
      setState(() => _testResult = result);
    });
  }

  Future<void> _fixFirewall() async {
    await _runAction(() async {
      final result = await widget.permissionManager.fixFirewall();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF0C1622),
          title: Text(result.success ? 'Firewall Updated' : 'Firewall Action'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.message),
              if (result.manualCommands.isNotEmpty) ...[
                const SizedBox(height: 12),
                _CommandBlock(command: result.manualCommands.join('\n')),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      await _reload();
    });
  }

  Future<void> _openManualConnection() async {
    final controller = TextEditingController();
    final endpoint = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0C1622),
        title: const Text('Manual Connection'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'IP address and port',
            hintText: '192.168.1.20:9002',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    await _waitForUiTransitionToSettle();
    controller.dispose();
    if (endpoint == null || endpoint.isEmpty) return;

    await _runAction(() async {
      final success = await widget.onManualConnect(endpoint);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Manual connection started. Waiting for the peer response.'
                : 'Manual connection failed.',
          ),
          backgroundColor: success ? null : Colors.redAccent,
        ),
      );
    });
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_runningAction) return;
    setState(() => _runningAction = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _runningAction = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final diagnostics = widget.discoveryDiagnostics;
    final connection = widget.connectionDiagnostics;
    final environment = _environment;

    return Scaffold(
      appBar: AppBar(title: const Text('Connection Readiness')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _ReadinessCard(
                  title: 'Permissions',
                  rows: [
                    _statusRow('LAN permission', _lan),
                    _statusRow('Discovery permission', _discovery),
                    _statusRow('Background service', _background),
                    _statusRow('File sharing', _fileSharing),
                  ],
                ),
                const SizedBox(height: 16),
                _ReadinessCard(
                  title: 'Network',
                  rows: [
                    _plainRow(
                      'Firewall',
                      _firewallLabel(environment?.firewall),
                      _firewallColor(environment?.firewall),
                    ),
                    _plainRow(
                      'Network profile',
                      environment?.networkProfile ?? 'Unknown',
                      _profileColor(environment?.networkProfile),
                    ),
                    _plainRow(
                      'Listening TCP port',
                      connection.serverListening
                          ? '$messagingPort'
                          : 'Not listening',
                      connection.serverListening
                          ? Colors.greenAccent
                          : Colors.redAccent,
                    ),
                    _plainRow(
                      'Discovery UDP port',
                      diagnostics?.isListening == true
                          ? '$discoveryPort'
                          : 'Not listening',
                      diagnostics?.isListening == true
                          ? Colors.greenAccent
                          : Colors.redAccent,
                    ),
                    _plainRow(
                      'Active interfaces',
                      _interfaceSummary(environment?.interfaces ?? const []),
                      (environment?.interfaces.isNotEmpty ?? false)
                          ? Colors.greenAccent
                          : Colors.orangeAccent,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _ReadinessCard(
                  title: 'Discovery And Direct TCP',
                  rows: [
                    _plainRow(
                      'Multicast lock',
                      defaultTargetPlatform == TargetPlatform.android
                          ? (diagnostics?.multicastLockHeld == true
                              ? 'Held'
                              : 'Released')
                          : 'Not required',
                      Colors.white70,
                    ),
                    _plainRow(
                      'UDP multicast',
                      diagnostics?.multicastJoined == true
                          ? discoveryMulticastAddress
                          : 'Not joined',
                      diagnostics?.multicastJoined == true
                          ? Colors.greenAccent
                          : Colors.orangeAccent,
                    ),
                    _plainRow(
                      'Last direct peer',
                      connection.lastDirectPeerSeenAt == null
                          ? 'None'
                          : '${connection.lastDirectPeerName ?? connection.lastDirectPeerId} at ${_time(connection.lastDirectPeerSeenAt!)}',
                      connection.lastDirectPeerSeenAt == null
                          ? Colors.orangeAccent
                          : Colors.greenAccent,
                    ),
                    _plainRow(
                      'Last discovered peer',
                      diagnostics?.lastPeerName == null
                          ? 'None'
                          : '${diagnostics!.lastPeerName} (${diagnostics.lastPeerIp})',
                      diagnostics?.lastPeerName == null
                          ? Colors.orangeAccent
                          : Colors.greenAccent,
                    ),
                    _plainRow(
                      'Direct peers',
                      '${connection.directPeerCount} online • ${connection.knownPeerCount} known',
                      connection.directPeerCount > 0
                          ? Colors.greenAccent
                          : Colors.white70,
                    ),
                    _plainRow(
                      'Last transport error',
                      connection.lastTransportError ?? 'None',
                      connection.lastTransportError == null
                          ? Colors.greenAccent
                          : Colors.redAccent,
                    ),
                  ],
                ),
                if (_testResult != null) ...[
                  const SizedBox(height: 16),
                  _ReadinessCard(
                    title: 'Connection Test',
                    rows: [
                      _boolRow('UDP loopback', _testResult!.udpLoopbackOk),
                      _boolRow('TCP loopback', _testResult!.tcpLoopbackOk),
                      _boolRow('TCP LAN address', _testResult!.tcpLanAddressOk),
                      _plainRow(
                        'Discovered peers',
                        _testResult!.discoveredPeers.isEmpty
                            ? 'None'
                            : _testResult!.discoveredPeers.join(', '),
                        Colors.white70,
                      ),
                      _plainRow(
                        'Last error',
                        _testResult!.lastError ?? 'None',
                        _testResult!.lastError == null
                            ? Colors.greenAccent
                            : Colors.redAccent,
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                _buildActions(),
              ],
            ),
    );
  }

  Widget _buildActions() {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        ElevatedButton.icon(
          onPressed: _runningAction ? null : _grantRequiredPermissions,
          icon: const Icon(Icons.lock_open_outlined),
          label: const Text('Grant required permissions'),
        ),
        ElevatedButton.icon(
          onPressed: _runningAction ? null : _startDiscovery,
          icon: const Icon(Icons.radar_outlined),
          label: const Text('Start discovery'),
        ),
        OutlinedButton.icon(
          onPressed: _runningAction ? null : _runConnectionTest,
          icon: const Icon(Icons.network_check_outlined),
          label: const Text('Run connection test'),
        ),
        OutlinedButton.icon(
          onPressed: _runningAction ? null : _fixFirewall,
          icon: const Icon(Icons.security_outlined),
          label: const Text('Fix firewall'),
        ),
        OutlinedButton.icon(
          onPressed: _runningAction
              ? null
              : () => widget.permissionManager.openAppSettings(),
          icon: const Icon(Icons.app_settings_alt_outlined),
          label: const Text('Open Android app settings'),
        ),
        OutlinedButton.icon(
          onPressed: _runningAction
              ? null
              : () =>
                  widget.permissionManager.openBatteryOptimizationSettings(),
          icon: const Icon(Icons.battery_saver_outlined),
          label: const Text('Open battery optimization settings'),
        ),
        OutlinedButton.icon(
          onPressed: _runningAction ? null : _openManualConnection,
          icon: const Icon(Icons.add_link_outlined),
          label: const Text('Show manual connection option'),
        ),
      ],
    );
  }

  _ReadinessRow _statusRow(String label, PermissionStatus? status) {
    final state = status?.state;
    return _ReadinessRow(
      label: label,
      value: status?.title ?? 'Unknown',
      color: switch (state) {
        PermissionReadiness.ready => Colors.greenAccent,
        PermissionReadiness.missingPermission => Colors.redAccent,
        PermissionReadiness.blockedByFirewall => Colors.redAccent,
        PermissionReadiness.blockedByBatteryOptimization => Colors.orangeAccent,
        PermissionReadiness.blockedByNetworkProfile => Colors.orangeAccent,
        PermissionReadiness.requiresManualAction => Colors.orangeAccent,
        PermissionReadiness.unsupported => Colors.white54,
        null => Colors.white54,
      },
      detail: status?.message,
    );
  }

  _ReadinessRow _boolRow(String label, bool value) {
    return _plainRow(
      label,
      value ? 'OK' : 'Failed',
      value ? Colors.greenAccent : Colors.redAccent,
    );
  }

  _ReadinessRow _plainRow(String label, String value, Color color) {
    return _ReadinessRow(label: label, value: value, color: color);
  }

  String _firewallLabel(FirewallReadiness? state) {
    return switch (state) {
      FirewallReadiness.ok => 'OK',
      FirewallReadiness.blocked => 'Blocked',
      FirewallReadiness.unknown => 'Unknown',
      FirewallReadiness.unsupported => 'Not applicable',
      null => 'Unknown',
    };
  }

  Color _firewallColor(FirewallReadiness? state) {
    return switch (state) {
      FirewallReadiness.ok => Colors.greenAccent,
      FirewallReadiness.blocked => Colors.redAccent,
      FirewallReadiness.unknown => Colors.orangeAccent,
      FirewallReadiness.unsupported => Colors.white54,
      null => Colors.white54,
    };
  }

  Color _profileColor(String? profile) {
    final lower = (profile ?? '').toLowerCase();
    if (lower.contains('private') || lower.contains('domain')) {
      return Colors.greenAccent;
    }
    if (lower.contains('public')) return Colors.orangeAccent;
    return Colors.white70;
  }

  String _interfaceSummary(List<DiscoveryInterface> interfaces) {
    if (interfaces.isEmpty) {
      return 'No active LAN/Wi-Fi/Ethernet interface found.';
    }
    return interfaces
        .map((entry) => '${entry.name} ${entry.address.address}')
        .join(', ');
  }

  String _time(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class _ReadinessCard extends StatelessWidget {
  final String title;
  final List<_ReadinessRow> rows;

  const _ReadinessCard({
    required this.title,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ...rows.map((row) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 4,
                        child: Text(
                          row.label,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 5,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.value,
                              style: TextStyle(
                                color: row.color,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (row.detail != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                row.detail!,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

class _ReadinessRow {
  final String label;
  final String value;
  final Color color;
  final String? detail;

  const _ReadinessRow({
    required this.label,
    required this.value,
    required this.color,
    this.detail,
  });
}

class _CommandBlock extends StatelessWidget {
  final String command;

  const _CommandBlock({required this.command});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(
        command,
        style: const TextStyle(
          fontFamily: 'monospace',
          color: Colors.white,
          height: 1.45,
        ),
      ),
    );
  }
}
